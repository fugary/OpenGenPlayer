#if os(macOS) || os(iOS)
import Foundation
import Combine
import Speech

struct MacAudioSubtitleBackend {
    var inspect: (URL) async throws -> MacAudioSubtitleSource
    var languages: () async -> [String]
    var available: () -> Bool
    var prepare: (String) async throws -> Void
    var transcribe: (MacAudioSubtitleSource, Int32, String, Int) async throws -> [MacAudioSubtitleCue]
    var revision: String
    // Preparation is part of the independent recognition backend, never the active player.
    var prepareAudio: (MacAudioSubtitleSource, Int32) async throws -> Void = { source, track in
        if source.decoder != .native {
            _ = try await MacAudioSubtitleRemux.shared.audioURL(source: source, trackID: track)
        }
    }

    static var live: Self {
        Self(inspect: MacAudioSubtitleSource.inspect, languages: {
            if #available(macOS 26.0, iOS 26.0, *) { return await SpeechTranscriber.supportedLocales.map(\.identifier).sorted() }
            return []
        }, available: {
            if #available(macOS 26.0, iOS 26.0, *) { return SpeechTranscriber.isAvailable }
            return false
        }, prepare: { language in
            guard #available(macOS 26.0, iOS 26.0, *) else { throw MacAudioSubtitleError.unavailable }
            try await MacAudioSubtitleEngine.prepare(language: language)
        }, transcribe: { source, track, language, chunk in
            guard #available(macOS 26.0, iOS 26.0, *) else { throw MacAudioSubtitleError.unavailable }
            return try await MacAudioSubtitleEngine.transcribe(source: source, trackID: track, language: language, chunk: chunk)
        }, revision: "apple-speech-" + ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

/// Configuration identity excludes recognition progress and the playback clock.
struct AudioSubtitleConfiguration: Equatable {
    struct Track: Equatable {
        let id: Int32
        let ordinal: Int
        let language: String?
        let name: String?
    }
    let sourceID: String?
    let tracks: [Track]
    let languages: [String]
    let selectedTrack: Int32
    let language: String
    let disabled: Bool
}

/// One player owns this model. All publication and controls run on the main thread.
final class MacAudioSubtitleJob: ObservableObject {
    enum Display: String, Codable { case off, primary, secondary, translatedSecondary, configured }
    enum Destination: String, Codable { case none, primary, secondary }
    private struct Preference: Codable {
        let track: Int32
        let language: String
        let display: Display
        var ordinal: Int? = nil
        var trackLanguage: String? = nil
        var originalDestination: Destination? = nil
        var translationDestination: Destination? = nil
        var automaticallyTranslate: Bool? = nil
    }
    private var continuationKey: String?
    private var applyingAutomaticDisplay = false

    static func continuationScope(url: URL, provider: String?, serverID: String?, seriesID: String?) -> String? {
        if let seriesID, !seriesID.isEmpty, let serverID, !serverID.isEmpty {
            return MacAudioSubtitlePlan.digest([provider ?? "", serverID, seriesID])
        }
        return url.isFileURL ? MacAudioSubtitlePlan.digest([url.deletingLastPathComponent().standardizedFileURL.path]) : nil
    }
    @Published private(set) var source: MacAudioSubtitleSource?
    private(set) var browserRevision = 0
    @Published private(set) var cache: MacAudioSubtitleCache? { didSet { browserRevision &+= 1 } }
    @Published private(set) var status = "AS.LocalOnly"
    @Published private(set) var running = false
    @Published private(set) var inspecting = false
    @Published private(set) var languages: [String] = []
    @Published private(set) var display: Display = .off
    @Published private(set) var automaticallyTranslate = false
    @Published private(set) var originalDestination: Destination = .primary
    @Published private(set) var translationDestination: Destination = .secondary
    private var hasOutputConfiguration = false
    private var configuredOriginal: Destination = .none
    private var configuredTranslation: Destination = .none

    var isConfigured: Bool { display == .configured }
    var activeOriginalDestination: Destination {
        switch display {
        case .primary: return .primary
        case .secondary: return .secondary
        case .configured: return configuredOriginal
        default: return .none
        }
    }
    var activeTranslationDestination: Destination {
        if display == .translatedSecondary { return .secondary }
        return isConfigured ? configuredTranslation : .none
    }
    func uses(_ destination: Destination) -> Bool {
        destination != .none && (activeOriginalDestination == destination || activeTranslationDestination == destination)
    }
    var hasActiveOutput: Bool { uses(.primary) || uses(.secondary) }
    var translatesAudio: Bool { activeTranslationDestination != .none }
    var needsSecondary: Bool {
        originalDestination == .secondary || (automaticallyTranslate && translationDestination == .secondary)
    }
    var outputAvailable: Bool { !needsSecondary || defaults.bool(forKey: "enableSecondarySubtitlesBeta") }
    var hasMatchingCache: Bool { cache != nil && activeTrack == selectedTrack && activeLanguage == language }
    var completedSelection: Bool { hasMatchingCache && cache?.isComplete == true }

    func setOriginalDestination(_ value: Destination) {
        originalDestination = value
        applyOutputConfiguration()
    }
    func setTranslationDestination(_ value: Destination) {
        guard value != .none else { return }
        translationDestination = value
        applyOutputConfiguration()
    }
    func applyOutputConfiguration() {
        hasOutputConfiguration = true
        noteManualSubtitleSelection()
        if hasMatchingCache && outputAvailable { select(.configured) }
        else if hasMatchingCache && isConfigured && !outputAvailable { select(.off) }
    }
    func release(_ destination: Destination) {
        guard isConfigured else { return }
        noteManualSubtitleSelection()
        if originalDestination == destination { originalDestination = .none }
        if automaticallyTranslate && translationDestination == destination { automaticallyTranslate = false }
        if configuredOriginal == destination { configuredOriginal = .none }
        if configuredTranslation == destination { configuredTranslation = .none }
        if !hasActiveOutput { select(.off) }
        else {
            persistPreference(updateContinuation: true)
            onDisplayChanged?(.configured)
        }
    }
    func useOrGenerate() {
        guard outputAvailable else { return }
        hasOutputConfiguration = true
        if completedSelection { select(.configured) }
        else { start() }
    }
    private func restoreOutput(_ preference: Preference) {
        automaticallyTranslate = preference.automaticallyTranslate ?? (preference.display == .translatedSecondary)
        originalDestination = preference.originalDestination ?? (preference.display == .translatedSecondary ? .none : (preference.display == .secondary ? .secondary : .primary))
        translationDestination = preference.translationDestination ?? .secondary
        hasOutputConfiguration = preference.display == .configured || preference.originalDestination != nil
    }
    @Published var selectedTrack: Int32 = -1 {
        didSet { if !selectingPlaybackDefault { needsPlaybackDefault = false } }
    }
    @Published var language = "" {
        didSet { if !selectingDefaultLanguage { allowsDefaultLanguage = false } }
    }
    var playbackAudioSelection: (() -> (id: Int, trackIDs: [Int])?)?
    private var selectingPlaybackDefault = false
    private var needsPlaybackDefault = true
    private var selectingDefaultLanguage = false
    private var allowsDefaultLanguage = true
    private var languageSuggestionTrack: Int32?
    private var defaultLanguageTask: Task<Void, Never>?
    var playbackTime = 0.0
    var onResultsChanged: (() -> Void)?
    var onDisplayChanged: ((Display) -> Void)?
    private let backend: MacAudioSubtitleBackend
    private let store: MacAudioSubtitleStore
    private let defaults: UserDefaults
    private var playbackReadAheadCache: MPVReadAheadByteCache?
    private var displayRevision = UUID()
    init(backend: MacAudioSubtitleBackend = .live, store: MacAudioSubtitleStore = .shared,
         defaults: UserDefaults = .standard) {
        self.backend = backend; self.store = store; self.defaults = defaults
    }
    private var generation = UUID()
    private var setupTask: Task<Void, Never>?
    private var inspectionContext: (url: URL, remote: MacJellyfinAudioSubtitles?, fileAudio: MP4AudioAccess?, selection: UUID)?
    private var work: Task<Void, Never>?
    private var chunkTask: Task<[MacAudioSubtitleCue], Error>?
    private var activeChunk: Int?
    private var cacheKey: String?
    // Once started, the source configuration is immutable until a new run is explicitly requested.
    private(set) var activeTrack: Int32?
    private(set) var activeLanguage: String?

    var configuration: AudioSubtitleConfiguration {
        .init(sourceID: source?.identity, tracks: (source?.tracks ?? []).map {
            .init(id: $0.id, ordinal: $0.ordinal, language: $0.language, name: $0.name)
        }, languages: Array(Set(languages + (language.isEmpty ? [] : [language]))).sorted(),
           selectedTrack: selectedTrack, language: language, disabled: running || inspecting)
    }
    var cues: [MacAudioSubtitleCue] { cache?.cues ?? [] }
    var allowsProcessing = true
    var canStart: Bool { allowsProcessing && source != nil && selectedTrack != -1 && !language.isEmpty && !running && !inspecting }
    var canDisplay: Bool { cache.map { !$0.isComplete || !$0.cues.isEmpty } ?? false }
    var progress: Double { guard let cache else { return 0 }; return cache.completedDuration / cache.duration }

    func refreshDefaultAudioTrack() {
        guard needsPlaybackDefault, !inspecting, !running, activeTrack == nil, let source else { return }
        let track: MacAudioSubtitleTrack?
        if let playback = playbackAudioSelection?() {
            track = source.playingTrack(id: playback.id, trackIDs: playback.trackIDs)
        } else { track = source.tracks.count == 1 ? source.tracks.first : nil }
        selectingPlaybackDefault = true
        if selectedTrack != (track?.id ?? -1) {
            selectedTrack = track?.id ?? -1
            defaultLanguageTask?.cancel()
            languageSuggestionTrack = nil
            if allowsDefaultLanguage {
                selectingDefaultLanguage = true; language = ""; selectingDefaultLanguage = false
            }
        }
        selectingPlaybackDefault = false
        guard let track, let code = track.language, language.isEmpty, allowsDefaultLanguage,
              languageSuggestionTrack != track.id else { return }
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        defaultLanguageTask?.cancel()
        languageSuggestionTrack = track.id
        let token = generation
        defaultLanguageTask = Task { @MainActor [weak self] in
            guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code)),
                  let self, self.generation == token, !Task.isCancelled,
                  self.selectedTrack == track.id, self.language.isEmpty, self.allowsDefaultLanguage else { return }
            self.selectingDefaultLanguage = true
            self.language = matched.identifier
            self.selectingDefaultLanguage = false
        }
    }

    func bind(url: URL?, live: Bool, remote: MacJellyfinAudioSubtitles? = nil,
              fileAudio: MP4AudioAccess? = nil, continuationScope: String? = nil) {
        reset()
        continuationKey = continuationScope.map { "audioSubtitleContinuation." + $0 }
        guard !live, let url, url.isFileURL || remote != nil || fileAudio != nil else { status = "AS.LocalOnly"; return }
        guard #available(macOS 26.0, iOS 26.0, *) else { status = "AS.Unavailable"; return }
        inspectionContext = (url, remote, fileAudio?.usingReadAheadCache(playbackReadAheadCache), displayRevision)
        // Remote file indexing is opt-in: opening an ordinary movie must not start a second reader.
        if fileAudio != nil { status = "AS.Ready"; return }
        retryInspectionIfNeeded()
    }

    /// Connects only the current MPV stream's app-owned byte cache. Other sources
    /// keep their existing independent range readers and result caches.
    func setPlaybackReadAheadCache(_ cache: MPVReadAheadByteCache?) {
        guard playbackReadAheadCache !== cache else { return }
        playbackReadAheadCache = cache
        guard let context = inspectionContext, let fileAudio = context.fileAudio else { return }
        let updatedAccess = fileAudio.usingReadAheadCache(cache)
        inspectionContext = (context.url, context.remote, updatedAccess, context.selection)

        if var source, let currentFileAudio = source.fileAudio {
            source.fileAudio = currentFileAudio.usingReadAheadCache(cache)
            self.source = source
        }

        // Replacing/attaching a cache lets an in-flight inspection use the new
        // blocks. Detaching it must not start a fallback read during teardown;
        // the current task can finish with its captured, same-source snapshot.
        if inspecting, cache != nil {
            setupTask?.cancel()
            setupTask = nil
            generation = UUID()
            inspecting = false
            retryInspectionIfNeeded()
        }
    }

    /// iOS calls this when entering the audio configuration page after a failed initial read.
    /// Keep the original selection revision so retrying cannot undo a manual subtitle choice.
    func retryInspectionIfNeeded(remote updatedRemote: MacJellyfinAudioSubtitles? = nil,
                                 playbackSource: MacAudioSubtitleSource? = nil) {
        guard source == nil, !running, let context = inspectionContext else { return }
        if inspecting {
            guard playbackSource != nil else { return }
            setupTask?.cancel()
            generation = UUID()
        }
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let url = context.url, remote = updatedRemote ?? context.remote
        inspectionContext = (url, remote, context.fileAudio, context.selection)
        let token = generation
        let initialSelection = context.selection
        inspecting = true
        status = "AS.Reading"
        setupTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let source: MacAudioSubtitleSource
                if !url.isFileURL, let access = context.fileAudio {
                    source = try await MacMP4AudioSubtitles.inspect(access, url: url)
                } else if !url.isFileURL, let remote {
                    if let playbackSource { source = playbackSource }
                    else { source = try await remote.inspect() }
                }
                else {
                    do { source = try await self.backend.inspect(url) }
                    catch {
                        let failure = error as NSError
                        let unreadable = (error as? MacAudioSubtitleError) == .unreadable ||
                            (failure.domain == "GenPlayerVLCAudioReader" && failure.code == NSFileReadCorruptFileError)
                        guard unreadable else { throw error }
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 350_000_000)
                        source = try await self.backend.inspect(url)
                    }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.source = source
                let languages = await self.backend.languages()
                guard self.generation == token, !Task.isCancelled else { return }
                self.languages = languages
                self.inspecting = false
                self.status = self.backend.available() ? "AS.Ready" : "AS.Unavailable"
                let key = "macAudioSubtitle." + source.identity
                if let data = self.defaults.data(forKey: key),
                   let pref = try? JSONDecoder().decode(Preference.self, from: data),
                   source.tracks.contains(where: { $0.id == pref.track }) {
                    self.selectedTrack = pref.track
                    self.language = pref.language
                    if self.displayRevision == initialSelection { self.restoreOutput(pref) }
                    // Completed results can be read even when the engine is temporarily unavailable.
                    self.start(restore: self.displayRevision == initialSelection ? pref.display : .off)
                } else if self.displayRevision == initialSelection,
                          let key = self.continuationKey, let data = self.defaults.data(forKey: key),
                          let pref = try? JSONDecoder().decode(Preference.self, from: data), pref.display != .off,
                          let track = self.continuationTrack(pref, in: source) {
                    self.selectedTrack = track.id
                    self.language = pref.language
                    if self.displayRevision == initialSelection { self.restoreOutput(pref) }
                    self.start(restore: pref.display)
                } else { self.refreshDefaultAudioTrack() }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.inspecting = false
                self.status = (error as? MacAudioSubtitleError)?.rawValue
                    ?? (context.fileAudio != nil ? (context.fileAudio?.kind == "smb" ? "AS.SMBFailed" : "AS.FileFailed") :
                        (remote != nil && !url.isFileURL ? "AS.RemoteFailed" : "AS.Unreadable"))
            }
        }
    }

    func reset() {
        generation = UUID()
        setupTask?.cancel(); setupTask = nil
        defaultLanguageTask?.cancel(); defaultLanguageTask = nil
        inspectionContext = nil
        work?.cancel()
        chunkTask?.cancel(); chunkTask = nil
        activeChunk = nil
        source = nil; cache = nil; cacheKey = nil
        continuationKey = nil
        activeTrack = nil; activeLanguage = nil
        running = false; inspecting = false; display = .off
        automaticallyTranslate = false
        originalDestination = defaults.bool(forKey: "enableSecondarySubtitlesBeta") ? .secondary : .primary
        translationDestination = .secondary
        hasOutputConfiguration = false
        configuredOriginal = .none; configuredTranslation = .none
        selectedTrack = -1; language = ""; languages = []
        needsPlaybackDefault = true
        allowsDefaultLanguage = true; languageSuggestionTrack = nil
        onResultsChanged?()
    }

    func cancel() {
        generation = UUID()
        work?.cancel()
        chunkTask?.cancel()
        activeChunk = nil
        running = false
        status = "AS.Cancelled"
    }

    func seek(to time: Double) {
        playbackTime = time
        guard let activeChunk, let cache,
              let next = MacAudioSubtitlePlan.next(at: time, duration: cache.duration, completed: Set(cache.chunks.keys)),
              next != activeChunk else { return }
        chunkTask?.cancel()
    }

    func noteManualSubtitleSelection() { displayRevision = UUID() }

    func setAutomaticallyTranslate(_ value: Bool) {
        automaticallyTranslate = value
        applyOutputConfiguration()
    }

    func select(_ value: Display) {
        guard value == .off || canDisplay else { return }
        displayRevision = UUID()
        if value == .configured {
            configuredOriginal = originalDestination
            configuredTranslation = automaticallyTranslate ? translationDestination : .none
        }
        display = value
        if value == .primary || value == .secondary {
            automaticallyTranslate = false
            originalDestination = value == .primary ? .primary : .secondary
        } else if value == .translatedSecondary {
            automaticallyTranslate = true
            originalDestination = .none
            translationDestination = .secondary
        }
        persistPreference(updateContinuation: !applyingAutomaticDisplay)
        onDisplayChanged?(value)
    }

    private func selectAutomatically(_ value: Display) {
        let previous = applyingAutomaticDisplay
        applyingAutomaticDisplay = true
        defer { applyingAutomaticDisplay = previous }
        select(value)
    }

    private func continuationTrack(_ preference: Preference, in source: MacAudioSubtitleSource) -> MacAudioSubtitleTrack? {
        if let language = preference.trackLanguage {
            let matches = source.tracks.filter { $0.language == language }
            if matches.count == 1 { return matches[0] }
            return matches.first { $0.ordinal == preference.ordinal }
        }
        if source.tracks.count == 1 { return source.tracks[0] }
        return source.tracks.first { $0.ordinal == preference.ordinal && $0.language == nil }
    }

    private func persistPreference(updateContinuation: Bool) {
        guard let source, let track = activeTrack, let language = activeLanguage else { return }
        let selected = source.tracks.first { $0.id == track }
        let value = Preference(track: track, language: language, display: display,
                               ordinal: selected?.ordinal, trackLanguage: selected?.language,
                               originalDestination: isConfigured ? configuredOriginal : originalDestination,
                               translationDestination: isConfigured && configuredTranslation != .none ? configuredTranslation : translationDestination,
                               automaticallyTranslate: isConfigured ? configuredTranslation != .none : automaticallyTranslate)
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: "macAudioSubtitle." + source.identity)
            if updateContinuation, let continuationKey { defaults.set(data, forKey: continuationKey) }
        }
    }

    func start(restore: Display? = nil) {
        guard #available(macOS 26.0, iOS 26.0, *), allowsProcessing, let source, !running, !inspecting,
              source.tracks.contains(where: { $0.id == selectedTrack }), !language.isEmpty else { return }
        work?.cancel(); chunkTask?.cancel()
        let previous = work
        let token = UUID()
        generation = token
        let track = selectedTrack, language = language
        running = true; status = "AS.Reading"
        // Do not restore remote cues produced with the old, clamped tail offset.
        // Keep source identity stable so audio/language/display preferences still restore.
        let key = MacAudioSubtitlePlan.key(source: source.identity, track: track, language: language,
                                          engine: backend.revision + (source.remote == nil ? "" : "-jellyfin-seek-v2"))
        let selectionToken = displayRevision
        let sharedReadCache = source.fileAudio?.access.sharedReadAheadCache
        let readUsageBefore = sharedReadCache?.audioSubtitleReadUsage()
        work = Task { @MainActor [weak self] in
            defer {
                if let sharedReadCache, let readUsageBefore {
                    let after = sharedReadCache.audioSubtitleReadUsage()
                    let reused = after.reusedBytes &- readUsageBefore.reusedBytes
                    let sourceBytes = after.sourceBytes &- readUsageBefore.sourceBytes
                    if reused > 0 || sourceBytes > 0 {
                        NSLog("[MPV audio subtitle byte cache] reused=\(reused) source=\(sourceBytes) bytes")
                    }
                }
            }
            // A cancelled prior task must release its lease before this one tries to acquire it.
            await previous?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            let cached = await self.store.load(key: key, duration: source.duration)
            guard self.generation == token, !Task.isCancelled else { return }
            let secondaryEnabled = self.defaults.bool(forKey: "enableSecondarySubtitlesBeta")
            let preferredDisplay = restore ?? (self.hasOutputConfiguration ? .configured : (secondaryEnabled ? .secondary : .primary))
            let availableDisplay: Display = (preferredDisplay == .secondary || preferredDisplay == .translatedSecondary) && !secondaryEnabled ? .primary : preferredDisplay
            let supportedDisplay: Display = availableDisplay == .configured && !self.outputAvailable ? .off : availableDisplay
            let requestedDisplay = self.displayRevision == selectionToken ? supportedDisplay : self.display
            let remembersContinuation = restore == nil && self.displayRevision == selectionToken
            if self.cacheKey != key { self.selectAutomatically(.off) }
            self.cacheKey = key; self.cache = cached
            self.activeTrack = track; self.activeLanguage = language
            self.onResultsChanged?()
            self.selectAutomatically(requestedDisplay)
            self.persistPreference(updateContinuation: remembersContinuation)
            if cached.isComplete {
                self.running = false; self.status = cached.cues.isEmpty ? "AS.NoSpeech" : "AS.Completed"
                return
            }
            // Opening a file whose generated subtitles were explicitly turned off only loads cache.
            if restore == .off { self.running = false; self.status = "AS.Cached"; return }
            guard await MacAudioSubtitleLease.shared.acquire(token) else {
                guard self.generation == token else { return }
                self.running = false; self.status = "AS.Busy"; return
            }
            do {
                try Task.checkCancellation()
                guard self.generation == token else { throw CancellationError() }
                // Reload after acquiring the process-wide lease: another window may have finished chunks.
                let latest = await self.store.load(key: key, duration: source.duration)
                guard self.generation == token, !Task.isCancelled else { throw CancellationError() }
                self.cache = latest
                self.onResultsChanged?()
                if !latest.isComplete {
                    if source.decoder != .native {
                        self.status = "AS.PreparingAudio"
                        try await self.backend.prepareAudio(source, track)
                        try Task.checkCancellation()
                        guard self.generation == token else { throw CancellationError() }
                    }
                    self.status = "AS.Preparing"
                    try await self.backend.prepare(language)
                }
                while !Task.isCancelled && self.generation == token, let current = self.cache,
                      let chunk = MacAudioSubtitlePlan.next(at: self.playbackTime, duration: source.duration,
                                                           completed: Set(current.chunks.keys)) {
                    self.status = "AS.Generating"
                    self.activeChunk = chunk
                    let transcribe = self.backend.transcribe
                    let task = Task { try await transcribe(source, track, language, chunk) }
                    self.chunkTask = task
                    let result: [MacAudioSubtitleCue]
                    do { result = try await task.value }
                    catch {
                        // A seek cancels only this segment; closing/retrying cancels the entire generation.
                        if task.isCancelled, !Task.isCancelled, self.generation == token { continue }
                        throw error
                    }
                    try Task.checkCancellation()
                    guard self.generation == token else { throw CancellationError() }
                    var updated = current
                    updated.chunks[chunk] = result
                    do { try await self.store.save(updated) }
                    catch { throw MacAudioSubtitleError.storage }
                    guard self.generation == token, !Task.isCancelled else { throw CancellationError() }
                    self.cache = updated
                    self.onResultsChanged?()
                }
                if self.generation == token, !Task.isCancelled {
                    self.status = self.cues.isEmpty ? "AS.NoSpeech" : "AS.Completed"
                    if self.cues.isEmpty { self.selectAutomatically(.off) }
                }
            } catch {
                if self.generation == token, !Task.isCancelled {
                    self.status = (error as? MacAudioSubtitleError)?.rawValue ?? "AS.Failed"
                }
            }
            await MacAudioSubtitleLease.shared.release(token)
            if self.generation == token { self.running = false; self.activeChunk = nil; self.chunkTask = nil }
        }
    }

    func deleteCache() {
        guard let key = cacheKey else { return }
        cancel()
        select(.off)
        let previous = work
        let token = generation
        inspecting = true
        setupTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            guard await MacAudioSubtitleLease.shared.acquire(token) else {
                if self.generation == token { self.inspecting = false; self.status = "AS.Busy" }
                return
            }
            do {
                try await self.store.remove(key: key)
                await MacAudioSubtitleLease.shared.release(token)
                guard self.generation == token else { return }
                self.cache = nil; self.cacheKey = nil
                self.inspecting = false; self.status = "AS.Ready"
                if let source = self.source { self.defaults.removeObject(forKey: "macAudioSubtitle." + source.identity) }
                self.onResultsChanged?()
            } catch {
                await MacAudioSubtitleLease.shared.release(token)
                guard self.generation == token else { return }
                self.inspecting = false; self.status = "AS.StorageFailed"
            }
        }
    }

    func activeCues(at time: Double) -> [MacAudioSubtitleCue] {
        guard time.isFinite, time >= 0, let cache, time < cache.duration else { return [] }
        let chunk = Int(time / MacAudioSubtitlePlan.chunkSeconds)
        return (cache.chunks[chunk] ?? []).filter { $0.start <= time && time < $0.end }
    }

    func text(at time: Double) -> String {
        activeCues(at: time).map(\.text).joined(separator: "\n")
    }
}
#endif
