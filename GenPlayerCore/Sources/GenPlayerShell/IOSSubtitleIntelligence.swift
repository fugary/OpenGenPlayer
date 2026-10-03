#if os(iOS)
import SwiftUI
import Combine
import GenPlayerCore

/// iOS player adapter. The existing macOS-named algorithms stay internal to the package.
/// Call from the main thread, just like the player models it owns.
public final class IOSSubtitleIntelligence: ObservableObject {
    public static let generatedPrimaryID = -900002
    public static let generatedSecondaryID = -900003
    public static let translatedSecondaryID = -900004
    let audio: MacAudioSubtitleJob
    let translation: MacSubtitleTranslation
    @Published public var showingSettings = false
    public private(set) var showsAudioSettings = false
    public func presentSettings(audio: Bool) {
        showsAudioSettings = audio
        showingSettings = true
    }
    func prepareAudioSettings() {
        guard showsAudioSettings, !suspended else { return }
        onAudioSourceNeeded?()
        audio.retryInspectionIfNeeded()
        audio.refreshDefaultAudioTrack()
    }
    @Published public var hasSelectedPrimarySubtitle = false
    public var canTranslatePrimary: Bool { hasSelectedPrimarySubtitle || isGeneratedPrimary }
    @Published public private(set) var secondaryID = -1
    public var onGeneratedPrimarySelected: (() -> Void)?
    public var onIntelligentSecondarySelected: (() -> Void)?
    public var onPrimarySourceNeeded: (() -> Void)?
    public var onAudioSourceNeeded: (() -> Void)?
    public var usesIndependentPlaybackTrackIDs: (() -> Bool)?
    public var onPlaybackAudioSelection: (() -> (id: Int, trackIDs: [Int])?)?
    public func refreshDefaultAudioTrack() { audio.refreshDefaultAudioTrack() }
    public var onResultsChanged: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var audioNames: [(id: Int, name: String)] = []
    private var preferenceKey: String?
    private var suspended = false
    private var translatingGeneratedPrimary = false
    var primarySourceIsPartial = false
    private var decodedPrimary = MacMPVDecodedSubtitles(maximumTextBytes: 4 * 1024 * 1024)
    private var decodedLanguage: String?
    private var decodedTranslationKey: String?
    private var decodedFallbackSourceKey: String?
    private var failedBrowserSourceKey: String?
    private var translationFollowsAudio = false
    private var mediaGeneration = UUID()
    private var boundAudioURL: URL?

    private final class PlaybackMetadata {
        let data: Data
        let received = Date()
        init(_ data: Data) { self.data = data }
    }
    private static let playbackMetadata: NSCache<NSString, PlaybackMetadata> = {
        let cache = NSCache<NSString, PlaybackMetadata>()
        cache.countLimit = 8
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Short-lived, in-memory server responses; never persist signed playback URLs or credentials.
    public static func rememberPlaybackMetadata(_ data: Data, provider: String, serverID: String, itemID: String) {
        guard data.count <= 4 * 1024 * 1024 else { return }
        playbackMetadata.setObject(PlaybackMetadata(data), forKey: "\(provider)|\(serverID)|\(itemID)" as NSString, cost: data.count)
    }

    public convenience init() { self.init(audio: MacAudioSubtitleJob(), translation: MacSubtitleTranslation()) }
    init(audio: MacAudioSubtitleJob, translation: MacSubtitleTranslation) {
        self.audio = audio
        self.translation = translation
        audio.playbackAudioSelection = { [weak self] in
            guard let self, let selection = self.onPlaybackAudioSelection?() else { return nil }
            guard self.usesIndependentPlaybackTrackIDs?() == true,
                  let source = self.audio.source, source.decoder == .vlcRemux else { return selection }
            let ids = selection.trackIDs.filter { $0 != -1 }
            guard Set(ids).count == ids.count, ids.count == source.tracks.count,
                  let index = ids.firstIndex(of: selection.id),
                  let track = source.tracks.first(where: { $0.ordinal == index + 1 }) else { return (-1, []) }
            return (Int(track.id), source.tracks.map { Int($0.id) })
        }
        audio.objectWillChange.merge(with: translation.objectWillChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        audio.onResultsChanged = { [weak self] in
            self?.followGeneratedPrimary()
            self?.onResultsChanged?()
        }
        audio.onDisplayChanged = { [weak self] display in
            guard let self else { return }
            switch display {
            case .configured:
                self.applyConfiguredAudioOutput()
            case .primary:
                self.translationFollowsAudio = false
                if self.secondaryID == Self.generatedSecondaryID { self.secondaryID = -1 }
                self.onGeneratedPrimarySelected?()
                self.followGeneratedPrimary()
            case .translatedSecondary:
                self.translationFollowsAudio = true
                self.setTranslationEnabled(true, persist: false)
            case .secondary:
                self.translationFollowsAudio = false
                self.setTranslationEnabled(false)
                self.secondaryID = Self.generatedSecondaryID
                self.onIntelligentSecondarySelected?()
            case .off:
                if self.translationFollowsAudio {
                    self.translationFollowsAudio = false
                    self.setTranslationEnabled(false)
                }
                if self.secondaryID == Self.generatedSecondaryID { self.secondaryID = -1 }
                if self.translatingGeneratedPrimary {
                    self.translatingGeneratedPrimary = false
                    self.translation.clearSource(status: "Translation.SelectPrimary")
                    self.onPrimarySourceNeeded?()
                }
            }
            self.objectWillChange.send()
            self.onResultsChanged?()
        }
        translation.onResultsChanged = { [weak self] in self?.onResultsChanged?() }
    }

    public var hasGeneratedSubtitles: Bool { audio.canDisplay }
    public var isTranslatingAudio: Bool { audio.translatesAudio }
    public var isGeneratedPrimary: Bool { audio.uses(.primary) }
    public var isTranslating: Bool { secondaryID == Self.translatedSecondaryID || (audio.isConfigured && audio.translatesAudio) }
    public var generatedName: String {
        let track = audio.source?.tracks.first { $0.id == audio.activeTrack }
        let name: String?
        if let original = track?.name { name = original }
        else if let track, audio.source?.remote == nil {
            let sharesTrackIDs = audio.source?.decoder == .vlcRemux && usesIndependentPlaybackTrackIDs?() != true
            let byID = sharesTrackIDs ? audioNames.first { $0.id == Int(track.id) }?.name : nil
            name = byID ?? (audioNames.indices.contains(track.ordinal - 1) ? audioNames[track.ordinal - 1].name : nil)
        } else { name = nil }
        return String(format: platformShellString("AS.GeneratedName"),
                      name ?? String(format: platformShellString("AS.TrackName"), track?.ordinal ?? 1))
    }
    public func updateAudioNames(_ names: [(id: Int, name: String)]) { audioNames = names.filter { $0.id != -1 } }

    public func bind(url: URL, live: Bool, provider: String?, serverID: String?, itemID: String?,
                     serverURL: URL?, token: String?, mediaSourceID: String?, seriesID: String? = nil, filePath: String? = nil) {
        reset()
        boundAudioURL = url
        preferenceKey = MacSubtitleTranslationPreference.key(provider: provider, serverID: serverID, itemID: itemID, url: url)
        translation.bindPreference(key: preferenceKey)
        var remote: MacJellyfinAudioSubtitles?
        if !url.isFileURL, let remoteProvider = MacJellyfinAudioSubtitles.Provider(rawValue: provider ?? ""), let serverURL, let serverID, let itemID, let token {
            remote = .init(serverURL: serverURL, serverID: serverID, itemID: itemID,
                           mediaSourceID: mediaSourceID?.isEmpty == false ? mediaSourceID : nil, token: token, provider: remoteProvider)
        }
        var fileAudio: MP4AudioAccess?
        var fileAudioScope: String?
        if !live, provider == "smb", url.scheme?.lowercased() == "smb",
           ["mp4", "m4v"].contains(url.pathExtension.lowercased()),
           var clean = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Construction is lazy; DNS, login and file reads start only at page entry.
            let reader = SMBAudioRangeReader(url: url)
            clean.user = nil; clean.password = nil; clean.query = nil; clean.fragment = nil
            if let identityURL = clean.url {
                fileAudioScope = MacAudioSubtitlePlan.digest(["smb", serverID ?? "",
                    identityURL.deletingLastPathComponent().absoluteString])
                fileAudio = MP4AudioAccess(identity: MacAudioSubtitlePlan.digest([serverID ?? "", identityURL.absoluteString]), metadata: {
                    let metadata = try await reader.metadata()
                    return .init(size: metadata.size, stamp: metadata.version)
                }, read: { try await reader.read(offset: $0, count: $1) })
            }
        }
        if !live, fileAudio == nil, FileAudioRangeReader.supports(provider: provider, url: url),
           ["mp4", "m4v"].contains(URL(fileURLWithPath: filePath ?? url.path).pathExtension.lowercased()),
           let identity = MP4AudioAccess.fileIdentity(url: url, provider: provider, serverID: serverID, path: filePath) {
            let kind = provider ?? "http"
            let reader = FileAudioRangeReader(url: url, provider: provider, serverID: serverID, path: filePath, itemID: itemID)
            fileAudioScope = identity.scope
            fileAudio = MP4AudioAccess(identity: identity.identity, metadata: {
                let value = try await reader.metadata()
                return .init(size: value.size, stamp: value.stamp)
            }, read: { try await reader.read(offset: $0, count: $1) }, kind: kind)
        }
        audio.bind(url: url, live: live, remote: remote, fileAudio: fileAudio,
            continuationScope: fileAudioScope ?? MacAudioSubtitleJob.continuationScope(url: url, provider: provider, serverID: serverID, seriesID: seriesID))
        if let key = preferenceKey, MacSubtitleTranslationPreference.isEnabled(key: key),
           UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") {
            setTranslationEnabled(true, persist: false)
        }
    }

    /// Replacing only the playback core must not restart recognition or reset chosen outputs.
    public func prepareForPlaybackRebuild() {
        decodedPrimary.select("")
        decodedLanguage = nil
        decodedTranslationKey = nil
        decodedFallbackSourceKey = nil
        failedBrowserSourceKey = nil
        primarySourceIsPartial = false
        if !isGeneratedPrimary && !isTranslatingAudio {
            mediaGeneration = UUID()
            translation.clearSource(status: "Translation.Reading")
        }
        onResultsChanged?()
    }

    public func reset() {
        hasSelectedPrimarySubtitle = false
        boundAudioURL = nil
        mediaGeneration = UUID()
        primarySourceIsPartial = false
        decodedPrimary.select("")
        decodedLanguage = nil
        decodedTranslationKey = nil
        decodedFallbackSourceKey = nil
        failedBrowserSourceKey = nil
        translatingGeneratedPrimary = false
        translationFollowsAudio = false
        audio.reset()
        audio.setPlaybackReadAheadCache(nil)
        translation.setEnabled(false)
        secondaryID = -1
        preferenceKey = nil
        translation.bindPreference(key: nil)
        audioNames = []
        suspended = false
        audio.allowsProcessing = true
    }

    /// Shares only the active MPV range-stream blocks with remote MP4 audio
    /// indexing/transcription. Other playback engines and direct server URLs pass nil.
    public func setPlaybackReadAheadCache(_ cache: MPVReadAheadByteCache?) {
        audio.setPlaybackReadAheadCache(cache)
    }

    public func retryAudioInspection(url: URL, provider: String?, serverID: String?, itemID: String?,
                                     serverURL: URL?, token: String?, mediaSourceID: String?,
                                     playbackMetadata: Data? = nil) {
        guard url == boundAudioURL, !url.isFileURL,
              let provider = MacJellyfinAudioSubtitles.Provider(rawValue: provider ?? ""),
              let serverID, let itemID, let serverURL, let token, !token.isEmpty else { return }
        let remote = MacJellyfinAudioSubtitles(serverURL: serverURL, serverID: serverID, itemID: itemID,
            mediaSourceID: mediaSourceID, token: token, provider: provider)
        var source: MacAudioSubtitleSource?
        let cached = Self.playbackMetadata.object(forKey: "\(provider.rawValue)|\(serverID)|\(itemID)" as NSString)
        let data = playbackMetadata ?? cached.flatMap { Date().timeIntervalSince($0.received) < 60 ? $0.data : nil }
        if let data {
            // Use exactly the same validation and fingerprint as the independent request.
            source = try? remote.source(from: Self.normalizedPlaybackMetadata(data))
        }
        audio.retryInspectionIfNeeded(remote: remote, playbackSource: source)
    }

    static func normalizedPlaybackMetadata(_ data: Data) -> Data {
        guard var info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sources = info["MediaSources"] as? [[String: Any]], sources.count == 1,
              (sources[0]["MediaStreams"] as? [[String: Any]] ?? []).isEmpty,
              let streams = info["MediaStreams"] as? [[String: Any]], !streams.isEmpty else { return data }
        sources[0]["MediaStreams"] = streams
        info["MediaSources"] = sources
        return (try? JSONSerialization.data(withJSONObject: info)) ?? data
    }

    private func applyConfiguredAudioOutput() {
        // Cache-only work does not own either displayed subtitle or ordinary translation.
        if !audio.hasActiveOutput && !translationFollowsAudio && !translatingGeneratedPrimary && secondaryID != Self.generatedSecondaryID { return }
        if let key = preferenceKey { MacSubtitleTranslationPreference.save(false, key: key) }
        translationFollowsAudio = audio.translatesAudio
        if audio.uses(.primary) { onGeneratedPrimarySelected?() }
        if audio.uses(.secondary) {
            secondaryID = audio.activeTranslationDestination == .secondary ? Self.translatedSecondaryID : Self.generatedSecondaryID
            onIntelligentSecondarySelected?()
        } else if secondaryID == Self.generatedSecondaryID || secondaryID == Self.translatedSecondaryID {
            secondaryID = -1
        }
        if audio.translatesAudio {
            translation.setEnabled(!suspended)
            translation.followsAudioRouting = true
            followGeneratedPrimary()
        } else if translation.enabled {
            translatingGeneratedPrimary = false
            translation.setEnabled(false)
        }
        onResultsChanged?()
    }

    public var isTranslatingPrimary: Bool { isTranslating && !isTranslatingAudio }

    public func setPrimaryTranslationEnabled(_ value: Bool) {
        if value && audio.translatesAudio {
            let preserveOriginal = audio.activeOriginalDestination == .primary
            audio.select(preserveOriginal ? .primary : .off)
        }
        setTranslationEnabled(value)
    }

    public func setTranslationEnabled(_ value: Bool, persist: Bool = true) {
        if persist && audio.isConfigured && audio.translatesAudio {
            audio.setAutomaticallyTranslate(value)
            if let key = preferenceKey { MacSubtitleTranslationPreference.save(false, key: key) }
            return
        }
        if value && audio.isConfigured {
            // The existing Translate Primary entry still follows the primary source.
            audio.release(.secondary)
            if audio.isConfigured { audio.select(audio.uses(.primary) ? .primary : .off) }
        }
        if value {
            guard #available(iOS 18.0, *) else { return }
            if persist { audio.noteManualSubtitleSelection() }
            if audio.display == .secondary { audio.select(.off) }
            secondaryID = Self.translatedSecondaryID
            translation.setEnabled(!suspended)
            onIntelligentSecondarySelected?()
            if isGeneratedPrimary || isTranslatingAudio { followGeneratedPrimary() } else { onPrimarySourceNeeded?() }
        } else {
            translatingGeneratedPrimary = false
            decodedTranslationKey = nil
            decodedFallbackSourceKey = nil
            primarySourceIsPartial = false
            translation.setEnabled(false)
            if secondaryID == Self.translatedSecondaryID { secondaryID = -1 }
            if audio.display == .translatedSecondary { audio.select(.secondary) }
        }
        if persist, let key = preferenceKey { MacSubtitleTranslationPreference.save(value, key: key) }
        onResultsChanged?()
    }

    public func selectGeneratedPrimary() {
        audio.noteManualSubtitleSelection()
        if audio.isConfigured { audio.setOriginalDestination(.primary) }
        else { audio.select(.primary) }
    }
    public func selectSecondary(_ id: Int) {
        if audio.isConfigured {
            if id == Self.generatedSecondaryID { audio.setOriginalDestination(.secondary); return }
            if id == Self.translatedSecondaryID {
                if audio.translatesAudio {
                    audio.setTranslationDestination(.secondary)
                } else { setTranslationEnabled(true) }
                return
            }
            audio.release(.secondary)
            return
        }
        if id == Self.translatedSecondaryID { setTranslationEnabled(true); return }
        setTranslationEnabled(false)
        audio.noteManualSubtitleSelection()
        if id == Self.generatedSecondaryID { audio.select(.secondary) }
        else if audio.display == .secondary || audio.display == .translatedSecondary { audio.select(.off) }
        secondaryID = id == Self.generatedSecondaryID && audio.display == .secondary ? id : -1
    }
    public func selectedOrdinaryPrimary(isOff: Bool) {
        audio.noteManualSubtitleSelection()
        if audio.isConfigured {
            audio.release(.primary)
            return
        }
        if audio.display == .primary { audio.select(.off) }
        if isOff && !isTranslatingAudio { setTranslationEnabled(false) }
    }
    /// Only observations from the selected mpv track. Does not start translation or any media read.
    public func updateDecodedPrimary(key: String?, language: String?, text: String, start: Double?, end: Double?) {
        let key = key ?? ""
        let oldRevision = decodedPrimary.revision
        if decodedPrimary.key != key {
            let wasTranslatingDecoded = decodedTranslationKey != nil
            decodedPrimary.select(key)
            decodedTranslationKey = nil
            decodedFallbackSourceKey = nil
            failedBrowserSourceKey = nil
            if wasTranslatingDecoded && isTranslatingPrimary && !isGeneratedPrimary {
                primarySourceIsPartial = false
                translation.clearSource(status: "Translation.Reading")
            }
        }
        decodedLanguage = language
        if !key.isEmpty { decodedPrimary.append(text: text, start: start, end: end) }
        guard decodedPrimary.revision != oldRevision else { return }
        if decodedTranslationKey == key { followDecodedPrimary(key: key) }
        onResultsChanged?()
    }

    public func followDecodedPrimary(key: String) {
        guard !key.isEmpty, decodedPrimary.key == key, isTranslating, !suspended,
              !isGeneratedPrimary, !isTranslatingAudio else { return }
        translatingGeneratedPrimary = false
        decodedTranslationKey = key
        primarySourceIsPartial = true
        translation.followGenerated(key: "\(mediaGeneration)|decoded|\(key)", language: decodedLanguage,
            cues: decodedPrimary.cues.map { MacAudioSubtitleCue(id: $0.id, start: $0.start, end: $0.end, text: $0.text) })
    }

    /// A stable full-source revision avoids cancelling an ongoing read on every decoded line.
    /// Once it fails, subsequent revisions are memory-only and never retry network reads per tick.
    public func decodedPrimaryBrowserSource(key: String, title: String, offset: Double,
                                             fullSource: SubtitleBrowserSource?) -> SubtitleBrowserSource? {
        guard !key.isEmpty, decodedPrimary.key == key else { return fullSource }
        let usesDecoded = fullSource == nil || failedBrowserSourceKey == fullSource?.requestKey
        let revision = usesDecoded ? "decoded-\(decodedPrimary.revision)" : fullSource!.revision
        return SubtitleBrowserSource(id: fullSource?.id ?? "\(key)|decoded", title: title, revision: revision, offset: offset) { [weak self] in
            try Task.checkCancellation()
            guard let self, self.decodedPrimary.key == key else { throw CancellationError() }
            if !usesDecoded, let fullSource {
                do {
                    let document = try await fullSource.load()
                    try Task.checkCancellation()
                    guard self.decodedPrimary.key == key else { throw CancellationError() }
                    return document
                }
                catch {
                    try Task.checkCancellation()
                    guard self.decodedPrimary.key == key else { throw CancellationError() }
                    if error is CancellationError { throw error }
                    if case SubtitleBrowserError.bitmap = error { throw error }
                    self.failedBrowserSourceKey = fullSource.requestKey
                }
            }
            return SubtitleBrowserDocument(parts: self.decodedPrimary.cues.map {
                SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
            }, isPartial: true, partialStatusKey: "SB.Decoded")
        }
    }

    public func followPrimary(key: String, language: String?, load: @escaping () async throws -> SubtitleTimeline) {
        guard isTranslating, !suspended, !isGeneratedPrimary, !isTranslatingAudio else { return }
        translatingGeneratedPrimary = false
        decodedTranslationKey = nil
        decodedFallbackSourceKey = nil
        translation.follow(key: "\(mediaGeneration)|\(key)", language: language) { [weak self] in
            try Task.checkCancellation()
            self?.primarySourceIsPartial = false
            return try await load()
        }
    }
    public func followPrimaryDocument(key: String, language: String?, decodedFallbackKey: String? = nil,
                                      load: @escaping () async throws -> SubtitleBrowserDocument) {
        guard isTranslating, !suspended, !isGeneratedPrimary, !isTranslatingAudio else { return }
        if let decodedFallbackKey, decodedFallbackSourceKey == key, decodedTranslationKey == decodedFallbackKey {
            followDecodedPrimary(key: decodedFallbackKey)
            return
        }
        decodedTranslationKey = nil
        decodedFallbackSourceKey = nil
        translatingGeneratedPrimary = false
        translation.follow(key: "\(mediaGeneration)|\(key)", language: language) { [weak self] in
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            let generation = self.translation.generation
            self.primarySourceIsPartial = false
            let document: SubtitleBrowserDocument
            do { document = try await load() }
            catch {
                try Task.checkCancellation()
                guard self.translation.generation == generation else { throw CancellationError() }
                if error is CancellationError { throw error }
                if case SubtitleBrowserError.bitmap = error { throw error }
                guard let decodedFallbackKey, self.decodedPrimary.key == decodedFallbackKey else { throw error }
                self.decodedFallbackSourceKey = key
                self.followDecodedPrimary(key: decodedFallbackKey)
                // The incremental source now owns translation; the old loader must not publish an error.
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard self.translation.generation == generation else { throw CancellationError() }
            self.primarySourceIsPartial = document.isPartial
            return SubtitleTimeline(parts: document.entries.map {
                SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
            })
        }
    }
    public func unavailablePrimary(bitmap: Bool) {
        guard isTranslating, !suspended, !isGeneratedPrimary, !isTranslatingAudio else { return }
        primarySourceIsPartial = false
        decodedTranslationKey = nil
        decodedFallbackSourceKey = nil
        let status = bitmap ? "Translation.Bitmap" : "Translation.SelectPrimary"
        if translation.hasSource || translation.statusKey != status { translation.clearSource(status: status) }
    }
    private func followGeneratedPrimary() {
        guard isTranslating, !suspended, (isGeneratedPrimary || isTranslatingAudio), let key = audio.cache?.key else { return }
        translatingGeneratedPrimary = true
        decodedTranslationKey = nil
        decodedFallbackSourceKey = nil
        primarySourceIsPartial = false
        translation.followGenerated(key: "\(mediaGeneration)|\(key)", language: audio.activeLanguage, cues: audio.cues)
    }
    public func updateTime(_ time: Double) {
        audio.playbackTime = time
        translation.playbackTime = time
    }
    public func seek(to time: Double) { audio.seek(to: time); translation.playbackTime = time }
    public func primaryParts(at time: Double) -> [SubtitlePart] {
        guard isGeneratedPrimary else { return [] }
        if audio.isConfigured {
            return translation.audioParts(at: time, cues: audio.cues,
                original: audio.activeOriginalDestination == .primary, translated: audio.activeTranslationDestination == .primary)
        }
        return audio.activeCues(at: time).map { SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text)) }
    }
    public func secondaryParts(at time: Double) -> [SubtitlePart] {
        if audio.isConfigured && audio.uses(.secondary) {
            return translation.audioParts(at: time, cues: audio.cues,
                original: audio.activeOriginalDestination == .secondary, translated: audio.activeTranslationDestination == .secondary)
        }
        if secondaryID == Self.translatedSecondaryID {
            let parts = translation.activeParts(at: time, content: .translated)
            if !parts.isEmpty { return parts }
            if let feedback = translation.overlayFeedback(status: translation.statusKey) {
                return [SubtitlePart(start: time, end: time + 1,
                    text: NSAttributedString(string: translation.statusMessage(for: feedback.statusKey)))]
            }
            return []
        }
        if secondaryID == Self.generatedSecondaryID {
            return audio.activeCues(at: time).map { SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text)) }
        }
        return []
    }
    public func setBackground(_ background: Bool) {
        guard suspended != background else { return }
        suspended = background
        audio.allowsProcessing = !background
        if background {
            if audio.running { audio.cancel() }
            translation.suspend()
        } else if isTranslating {
            translation.resume()
            if isGeneratedPrimary || isTranslatingAudio { followGeneratedPrimary() } else { onPrimarySourceNeeded?() }
        }
    }
}

/// This stays attached to the player; presenting/dismissing settings never restarts a language download.
public struct IOSSubtitleIntelligenceHost: View {
    @ObservedObject private var model: IOSSubtitleIntelligence
    @Environment(\.scenePhase) private var scenePhase
    public init(model: IOSSubtitleIntelligence) { self.model = model }
    public var body: some View {
        MacSubtitleTranslationHost(model: model.translation)
            .onChange(of: scenePhase) { phase in
                if phase == .background { model.setBackground(true) }
                else if phase == .active { model.setBackground(false) }
            }
    }
}

public struct IOSSubtitleIntelligenceSettings: View, Equatable {
    @ObservedObject private var model: IOSSubtitleIntelligence
    @Environment(\.presentationMode) private var presentationMode
    public init(model: IOSSubtitleIntelligence) { self.model = model }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model }
    public var body: some View {
        Group {
            if #available(iOS 16.0, *) { NavigationStack { settingsContent } }
            else { NavigationView { settingsContent }.navigationViewStyle(.stack) }
        }
    }
    @ViewBuilder private var settingsContent: some View {
        if #available(iOS 26.0, *), model.showsAudioSettings {
            IOSAudioSubtitleSettings(model: model.audio, translation: model.translation) { presentationMode.wrappedValue.dismiss() }
                .onAppear { model.prepareAudioSettings() }
        } else { settingsForm }
    }
    private var settingsForm: some View {
        Form {
            if model.canTranslatePrimary || model.isTranslatingAudio {
            Section {
                if #available(iOS 18.0, *) {
                    Toggle(platformShellString("Translation.Primary"), isOn: Binding(get: { model.isTranslatingPrimary }, set: { model.setPrimaryTranslationEnabled($0) }))
                    if model.isTranslatingPrimary { IOSSubtitleTranslationSettings(model: model.translation) }
                } else { Text(platformShellString("SI.TranslationUnavailable")) }
            }
            }
            Section { Text(platformShellString({ if #available(iOS 26.0, *) { return "SI.Support" }; return "SI.TranslationSupport" }())).font(.footnote).foregroundColor(.secondary) }
        }
        .navigationTitle(platformShellString("Translation.Primary"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button(platformShellString("Done")) { presentationMode.wrappedValue.dismiss() }
        } }
    }
}

@available(iOS 18.0, *)
private struct IOSSubtitleTranslationSettings: View {
    @ObservedObject var model: MacSubtitleTranslation
    var body: some View {
        IOSTranslationSelectors(model: model, languages: model.languages, target: model.targetLanguage,
                                source: model.sourceOverride).equatable()
            // Only load the choice list here; the TranslationSession remains on the player.
            .task { await model.loadLanguages() }
        if model.sourceOverride.isEmpty, let detected = model.sourceLanguage {
            Text(String(format: platformShellString("Translation.DetectedFormat"), model.languageName(detected)))
                .font(.caption).foregroundColor(.secondary)
        }
        if model.enabled { Text(model.statusMessage(for: model.statusKey)).font(.footnote).foregroundColor(.secondary) }
        if model.canRetry { Button(platformShellString("Retry")) { model.retry() } }
    }
}

@available(iOS 18.0, *)
private struct IOSTranslationSelectors: View, Equatable {
    let model: MacSubtitleTranslation
    let languages: [String]
    let target: String
    let source: String
    @AppStorage("appLanguage") private var appLanguage = "system"
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.languages == rhs.languages && lhs.target == rhs.target && lhs.source == rhs.source
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 16) {
                languageLink(isSource: true)
                languageLink(isSource: false)
            }
        } else {
            HStack(spacing: 16) {
                languageLink(isSource: true).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundColor(.secondary).accessibilityHidden(true)
                languageLink(isSource: false).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func languageLink(isSource: Bool) -> some View {
        let title = platformShellString(isSource ? "Translation.Source" : "Translation.Target")
        let value = isSource ? source : target
        return NavigationLink {
            Form {
                Picker(title, selection: Binding(get: { isSource ? model.sourceOverride : model.targetLanguage }, set: {
                    if isSource { model.setSourceOverride($0) } else { model.setTarget($0) }
                })) {
                    if isSource { Text(platformShellString("Translation.Automatic")).tag("") }
                    ForEach(Array(Set(languages + (value.isEmpty ? [] : [value]))).sorted {
                        model.languageName($0) < model.languageName($1)
                    }, id: \.self) { code in
                        Text(model.languageName(code)).tag(code)
                    }
                }.pickerStyle(.inline)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(isSource && value.isEmpty ? platformShellString("Translation.Automatic") : model.languageName(value))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@available(iOS 26.0, *)
private struct IOSAudioSubtitleSettings: View {
    @ObservedObject var model: MacAudioSubtitleJob
    @ObservedObject var translation: MacSubtitleTranslation
    let onDone: () -> Void
    @AppStorage("enableSecondarySubtitlesBeta") private var secondaryEnabled = false
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var exportText = ""
    @State private var exportFailed = false
    var body: some View {
        Form {
            Section(footer: Text(platformShellString(model.source?.fileAudio != nil ? (model.source?.fileAudio?.access.kind == "smb" ? "SI.SMBPrivacy" : "SI.FilePrivacy") :
                (model.source?.remote == nil ? "SI.AudioPrivacy" : "SI.RemotePrivacy")))) {
                IOSAudioSubtitleSelectors(model: model, configuration: model.configuration, selectsTrack: true).equatable()
                IOSAudioSubtitleSelectors(model: model, configuration: model.configuration, selectsTrack: false).equatable()
                if model.source?.remote?.usesVideoRoute == true {
                    Text(platformShellString("AS.MultiTrackNetwork")).font(.footnote).foregroundColor(.secondary)
                }
            }
            Section {
                AudioSubtitleOutputControls(model: model, translation: translation)
            }
            Section {
                Text(platformShellString(model.status == "AS.Unavailable" ? "SI.AudioUnavailable" : model.status))
                if model.running || model.inspecting {
                    if model.status == "AS.Generating" { ProgressView(value: model.progress) }
                    else { ProgressView() }
                }
                if model.running { Button(platformShellString("AS.Cancel")) { model.cancel() } }
                else if !model.completedSelection || model.display == .off {
                    Button(platformShellString(model.completedSelection ? "AS.UseCached" : (model.automaticallyTranslate ? "SI.GenerateTranslate" : "AS.Start"))) { model.useOrGenerate() }
                        .disabled(!model.canStart || !model.outputAvailable)
                }
            }
            if let cache = model.cache {
                Section {
                    Text(String(format: platformShellString("AS.ProgressFormat"), cache.completedDuration / 60, cache.duration / 60))
                        .font(.footnote).foregroundColor(.secondary)
                    Button(platformShellString(cache.isComplete ? "AS.Export" : "AS.ExportPartial")) {
                        exportText = MacAudioSubtitlePlan.srt(model.cues); exporting = true
                    }.disabled(model.cues.isEmpty)
                    Button(platformShellString("AS.Delete"), role: .destructive) { confirmDelete = true }
                        .disabled(model.inspecting)
                }
            }
            if exportFailed { Section { Text(platformShellString("AS.StorageFailed")).foregroundColor(.red) } }
        }
        .navigationTitle(platformShellString("AS.Title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(platformShellString("Done"), action: onDone) } }
        .alert(platformShellString("AS.Delete"), isPresented: $confirmDelete) {
            Button(platformShellString("AS.Delete"), role: .destructive) { model.deleteCache() }
            Button(platformShellString("Cancel"), role: .cancel) {}
        } message: { Text(platformShellString("AS.DeleteConfirm")) }
        .fileExporter(isPresented: $exporting, document: MacGeneratedSubtitleDocument(text: exportText),
                      contentType: MacGeneratedSubtitleDocument.readableContentTypes[0], defaultFilename: "subtitle.\(model.activeLanguage ?? "und").generated.srt") { result in
            if case .failure = result { exportFailed = true }
        }
    }
}

@available(iOS 26.0, *)
private struct IOSAudioSubtitleSelectors: View, Equatable {
    let model: MacAudioSubtitleJob
    let configuration: AudioSubtitleConfiguration
    let selectsTrack: Bool
    @AppStorage("appLanguage") private var appLanguage = "system"
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.configuration == rhs.configuration && lhs.selectsTrack == rhs.selectsTrack }
    private func languageName(_ code: String) -> String {
        Locale(identifier: platformResolvedLanguage(for: appLanguage)).localizedString(forIdentifier: code) ?? code
    }
    var body: some View {
        if selectsTrack {
            Picker(platformShellString("AS.AudioTrack"), selection: Binding(get: { configuration.selectedTrack }, set: { model.selectedTrack = $0 })) {
                Text(platformShellString("AS.ChooseTrack")).tag(Int32(-1))
                ForEach(configuration.tracks, id: \.id) { track in
                    Text(track.name ?? String(format: platformShellString("AS.TrackFormat"), track.ordinal,
                        track.language.map(languageName) ?? platformShellString("AS.UnknownLanguage"))).tag(track.id)
                }
            }.pickerStyle(.navigationLink).disabled(configuration.disabled || configuration.sourceID == nil)
        } else {
            Picker(platformShellString("AS.Language"), selection: Binding(get: { configuration.language }, set: { model.language = $0 })) {
                Text(platformShellString("AS.ChooseLanguage")).tag("")
                ForEach(configuration.languages, id: \.self) { Text(languageName($0)).tag($0) }
            }.pickerStyle(.navigationLink).disabled(configuration.disabled || configuration.sourceID == nil)
        }
    }
}
#endif
