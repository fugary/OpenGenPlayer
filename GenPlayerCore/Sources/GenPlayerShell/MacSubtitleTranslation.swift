#if os(macOS) || os(iOS)
import Foundation
import Combine
import NaturalLanguage
import SwiftUI
import Translation
import GenPlayerCore

struct MacSubtitleTranslationFeedback: Equatable {
    let statusKey: String
    let isLoading: Bool
}

/// Owned by one player. Mutations and publication run on the main thread.
final class MacSubtitleTranslation: ObservableObject {
    enum DisplayContent: String, CaseIterable {
        case translated, bilingual, original
        var titleKey: String { "SI.Content." + rawValue }
    }
    @Published private(set) var displayContent: DisplayContent
    @Published private(set) var originalFirst: Bool

    func setDisplayContent(_ value: DisplayContent) {
        displayContent = value
        defaults.set(value.rawValue, forKey: "subtitleTranslationDisplayContent")
        onResultsChanged?()
    }
    func setOriginalFirst(_ value: Bool) {
        originalFirst = value
        defaults.set(value, forKey: "subtitleTranslationOriginalFirst")
        onResultsChanged?()
    }

    static let trackID = "mac.translate-primary"
    @Published private(set) var generation = UUID()
    @Published private(set) var sourceLanguage: String?
    @Published private(set) var statusKey = "Translation.SelectPrimary"
    @Published private(set) var canRetry = false
    @Published private(set) var hasSource = false
    @Published private(set) var enabled = false
    @Published private(set) var targetLanguage: String
    @Published private(set) var sourceOverride = ""
    @Published private(set) var languages: [String] = []
    var playbackTime = 0.0
    var followsAudioRouting = false
    var onResultsChanged: (() -> Void)?
    private var sourceKey: String?
    private var metadataLanguage: String?
    private(set) var browserRevision = 0
    private var cues: [MacSubtitleTranslationCue] = [] { didSet { browserRevision &+= 1 } }
    private var units: [MacSubtitleTranslationUnit] = []
    private var translated: [Int: String] = [:] { didSet { browserRevision &+= 1 } }
    private var loadTask: Task<Void, Never>?
    private var loader: (() async throws -> SubtitleTimeline)?

    private let defaults: UserDefaults
    private var preferenceKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayContent = DisplayContent(rawValue: defaults.string(forKey: "subtitleTranslationDisplayContent") ?? "") ?? .translated
        originalFirst = defaults.object(forKey: "subtitleTranslationOriginalFirst") as? Bool ?? true
        targetLanguage = defaults.string(forKey: "macSubtitleTranslationTargetLanguage")
            ?? platformResolvedLanguage(for: defaults.string(forKey: "appLanguage") ?? "system")
    }

    /// Called only when binding a media item, never on subtitle or ASR updates.
    func bindPreference(key: String?) {
        guard preferenceKey != key else { return }
        setEnabled(false)
        preferenceKey = key
        let fallback = defaults.string(forKey: "macSubtitleTranslationTargetLanguage")
            ?? platformResolvedLanguage(for: defaults.string(forKey: "appLanguage") ?? "system")
        targetLanguage = key.flatMap { defaults.string(forKey: $0 + ".targetLanguage") } ?? fallback
        // Freeze the first-use default so changes in another video cannot change this item.
        if let key { defaults.set(targetLanguage, forKey: key + ".targetLanguage") }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            followsAudioRouting = false
            sourceOverride = ""
            clearSource(status: "Translation.SelectPrimary")
        }
    }

    // iOS background suspension cancels work without treating it as the user's Off action.
    func suspend() {
        enabled = false
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
    }

    func resume() {
        enabled = true
        if !hasSource, loader != nil, !canRetry { loadSource() }
    }

    func clearSource(status: String) {
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        sourceKey = nil
        loader = nil
        cues = []
        units = []
        translated = [:]
        hasSource = false
        sourceLanguage = nil
        metadataLanguage = nil
        canRetry = false
        statusKey = status
        onResultsChanged?()
    }

    func follow(key: String, language: String?, load: @escaping () async throws -> SubtitleTimeline) {
        guard enabled, sourceKey != key else { return }
        sourceOverride = ""
        clearSource(status: "Translation.Reading")
        sourceKey = key
        metadataLanguage = language
        loader = load
        loadSource()
    }

    /// Stable IDs let newly completed audio chunks join the source without re-identifying old lines.
    func followGenerated(key: String, language: String?, cues generated: [MacAudioSubtitleCue]) {
        guard enabled else { return }
        let incoming = generated.map { MacSubtitleTranslationCue(index: $0.id, start: $0.start, end: $0.end, text: $0.text) }
        let newSource = sourceKey != key
        let previouslyHadSource = hasSource
        if newSource {
            sourceOverride = ""
            clearSource(status: "Translation.Reading")
            sourceKey = key
            metadataLanguage = language?.replacingOccurrences(of: "_", with: "-")
        } else if cues == incoming { return }
        cues = incoming
        updateUnits()
        hasSource = !cues.isEmpty
        // Appending ASR chunks must not tear down SwiftUI's session/download sheet. The running
        // loop reads current cues. Once detected, keep the language stable for this source.
        if newSource || sourceLanguage == nil { detectSourceLanguage() }
        if newSource || !previouslyHadSource {
            statusKey = hasSource ? preparationStatusKey : "Translation.Reading"
        }
        onResultsChanged?()
    }

    private func loadSource() {
        guard let loader else { return }
        let token = generation
        loadTask = Task { @MainActor [weak self] in
            do {
                let timeline = try await loader()
                guard let self, !Task.isCancelled, self.enabled, self.generation == token else { return }
                self.cues = timeline.parts.enumerated().compactMap { index, part in
                    let text = (part.text?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, part.start.isFinite, part.end.isFinite, part.end > part.start else { return nil }
                    return MacSubtitleTranslationCue(index: index, start: part.start, end: part.end, text: text)
                }
                self.updateUnits()
                self.hasSource = !self.cues.isEmpty
                self.detectSourceLanguage()
                self.statusKey = self.hasSource ? self.preparationStatusKey : "Translation.Unreadable"
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.statusKey = "Translation.ReadFailed"
                self.canRetry = true
            }
        }
    }

    func setTarget(_ value: String) {
        if let key = preferenceKey { defaults.set(value, forKey: key + ".targetLanguage") }
        defaults.set(value, forKey: "macSubtitleTranslationTargetLanguage")
        guard value != targetLanguage else { return }
        targetLanguage = value
        restart()
    }

    func setSourceOverride(_ value: String) {
        guard value != sourceOverride else { return }
        sourceOverride = value
        detectSourceLanguage()
        restart()
    }

    func retry() {
        if !hasSource {
            loadTask?.cancel()
            generation = UUID()
            canRetry = false
            statusKey = "Translation.Reading"
            loadSource()
        } else {
            restart()
        }
    }

    private func restart() {
        generation = UUID()
        translated = [:]
        canRetry = false
        if hasSource { statusKey = preparationStatusKey }
        else if loader != nil { loadTask?.cancel(); loadSource() }
        onResultsChanged?()
    }

    private func detectSourceLanguage() {
        if !sourceOverride.isEmpty { sourceLanguage = sourceOverride; return }
        let aliases = ["eng": "en", "zho": "zh", "chi": "zh", "jpn": "ja", "kor": "ko",
                       "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "spa": "es",
                       "por": "pt", "rus": "ru", "ita": "it", "ara": "ar", "hin": "hi"]
        if let raw = metadataLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !["", "und", "unknown", "auto", "mul"].contains(raw) {
            let normalized = aliases[raw] ?? raw
            // Chinese metadata often omits script; inspect text before choosing a variant.
            if normalized != "zh", normalized.range(of: "^[a-z]{2,3}(-[a-z]{2,8})*$", options: .regularExpression) != nil {
                sourceLanguage = normalized
                return
            }
        }
        let recognizer = NLLanguageRecognizer()
        let nearby = cues.filter { $0.end > playbackTime }.prefix(24)
        let sample = nearby.isEmpty ? Array(cues.prefix(24)) : Array(nearby)
        recognizer.processString(String(sample.map(\.text).joined(separator: "\n").prefix(6000)))
        let candidates = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
        sourceLanguage = candidates.first.flatMap { $0.value >= 0.55 ? $0.key.rawValue : nil }
    }

    func activeParts(at time: Double, content: DisplayContent? = nil) -> [SubtitlePart] {
        let displayContent = content ?? self.displayContent
        return units.compactMap { unit in
            guard let cue = unit.members.first(where: { $0.start <= time && time < $0.end }) else { return nil }
            let text: String
            switch displayContent {
            case .translated:
                guard let result = translated[unit.index] else { return nil }
                text = result
            case .original:
                text = unit.text
            case .bilingual:
                let result = translated[unit.index] ?? " "
                text = originalFirst ? unit.text + "\n" + result : result + "\n" + unit.text
            }
            let attributes: [NSAttributedString.Key: Any] = displayContent == .bilingual ? [
                NSAttributedString.Key("GenPlayerSubtitleOriginal"): unit.text,
                NSAttributedString.Key("GenPlayerSubtitleTranslation"): translated[unit.index] ?? " ",
                NSAttributedString.Key("GenPlayerSubtitleOriginalFirst"): originalFirst
            ] : [:]
            return SubtitlePart(start: cue.start, end: cue.end, text: NSAttributedString(string: text, attributes: attributes))
        }
    }

    /// Read-only snapshot; opening the browser never schedules translation work.
    func browserParts(content: DisplayContent) -> [SubtitlePart] {
        units.flatMap { unit -> [SubtitlePart] in
            let text: String
            switch content {
            case .original: text = unit.text
            case .translated:
                guard let result = translated[unit.index] else { return [] }
                text = result
            case .bilingual:
                let result = translated[unit.index]
                text = result.map { originalFirst ? unit.text + "\n" + $0 : $0 + "\n" + unit.text } ?? unit.text
            }
            return unit.members.map { SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: text)) }
        }
    }

    var browserTranslationIsPartial: Bool { !hasSource || translated.count < units.count }

    func audioParts(at time: Double, cues: [MacAudioSubtitleCue], original: Bool, translated: Bool) -> [SubtitlePart] {
        if translated { return activeParts(at: time, content: original ? .bilingual : .translated) }
        return original ? cues.filter { $0.start <= time && time < $0.end }.map {
            SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
        } : []
    }

    private func updateUnits() {
        let previous = Dictionary(uniqueKeysWithValues: units.map { ($0.index, $0) })
        units = MacSubtitleTranslationPlan.units(cues: cues)
        let unchanged = Set(units.filter { previous[$0.index] == $0 }.map(\.index))
        translated = translated.filter { unchanged.contains($0.key) }
    }

    @discardableResult
    func acceptTranslation(_ text: String, for unit: MacSubtitleTranslationUnit) -> Bool {
        guard units.contains(unit), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        translated[unit.index] = text
        return true
    }

    func overlayFeedback(status: String) -> MacSubtitleTranslationFeedback? {
        guard enabled else { return nil }
        let currentCues = cues.filter { $0.start <= playbackTime && playbackTime < $0.end }
        let hasTranslation = !activeParts(at: playbackTime, content: .translated).isEmpty
        switch status {
        case "Translation.Reading", "Translation.Preparing":
            return hasTranslation ? nil : MacSubtitleTranslationFeedback(statusKey: status, isLoading: true)
        case "Translation.Translating", "Translation.Ready":
            // Prefetching future lines is not a visible wait. A seek can require
            // a current line before the translation loop notices its new time.
            guard !currentCues.isEmpty, !hasTranslation else { return nil }
            return MacSubtitleTranslationFeedback(statusKey: "Translation.Current", isLoading: true)
        default:
            return MacSubtitleTranslationFeedback(statusKey: status, isLoading: false)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor func loadLanguages() async {
        guard languages.isEmpty else { return }
        languages = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
            .sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
    }

    func languageName(_ identifier: String) -> String {
        let appLanguage = platformResolvedLanguage(for: UserDefaults.standard.string(forKey: "appLanguage") ?? "system")
        return Locale(identifier: appLanguage).localizedString(forIdentifier: identifier) ?? identifier
    }

    private var preparationStatusKey: String {
        guard #available(macOS 13.0, iOS 16.0, *), let sourceLanguage else { return "Translation.Preparing" }
        return MacSubtitleTranslationPlan.isSameWrittenLanguage(source: sourceLanguage, target: targetLanguage)
            ? "Translation.SameLanguage" : "Translation.Preparing"
    }

    func statusMessage(for status: String) -> String {
        guard status == "Translation.SameLanguage" || status == "Translation.UnsupportedPair" else {
            return platformShellString(status)
        }
        func displayName(_ identifier: String) -> String {
            // Server metadata can use zh-TW/zh-CN; show the writing system explicitly.
            if #available(macOS 13.0, iOS 16.0, *) {
                let language = Locale.Language(identifier: identifier)
                if language.languageCode?.identifier == "zh", let script = language.script {
                    return languageName("zh-\(script.identifier)")
                }
            }
            return languageName(identifier)
        }
        let sourceName = sourceLanguage.map(displayName) ?? platformShellString("Translation.Automatic")
        return String(format: platformShellString(status), sourceName, displayName(targetLanguage))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor func translate(using session: TranslationSession, token: UUID) async {
        guard enabled, hasSource, generation == token else { return }
        guard let sourceLanguage else { statusKey = "Translation.ChooseSource"; return }
        let source = Locale.Language(identifier: sourceLanguage)
        let target = Locale.Language(identifier: targetLanguage)
        guard preparationStatusKey != "Translation.SameLanguage" else { statusKey = "Translation.SameLanguage"; return }
        let availability = await LanguageAvailability().status(from: source, to: target)
        guard !Task.isCancelled, generation == token else { return }
        guard availability != .unsupported else { statusKey = "Translation.UnsupportedPair"; return }
        let targetID = targetLanguage
        do {
            var prepared = false
            while !Task.isCancelled && enabled && generation == token {
                let batch = MacSubtitleTranslationPlan.batch(units: units, at: playbackTime, translated: Set(translated.keys))
                if batch.isEmpty {
                    if statusKey != "Translation.Ready" { statusKey = "Translation.Ready" }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let keys = Dictionary(uniqueKeysWithValues: batch.map {
                    ($0.index, MacSubtitleTranslationPlan.cacheKey(text: $0.text, source: sourceLanguage, target: targetID))
                })
                let saved = await MacSubtitleTranslationCache.shared.values(for: Array(keys.values))
                guard !Task.isCancelled, enabled, generation == token else { return }
                var usedCache = false
                for unit in batch where units.contains(unit) {
                    if let key = keys[unit.index], let text = saved[key], acceptTranslation(text, for: unit) {
                        usedCache = true
                    }
                }
                if usedCache {
                    onResultsChanged?()
                    continue
                }
                if !prepared {
                    // The SwiftUI-owned session presents Apple's download consent in this player.
                    // Cached subtitles remain usable without re-downloading language assets.
                    statusKey = "Translation.Preparing"
                    try await session.prepareTranslation()
                    guard !Task.isCancelled, enabled, generation == token else { return }
                    prepared = true
                    continue // A seek may have occurred while the download sheet was open.
                }
                statusKey = "Translation.Translating"
                let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index)) }
                let responses = try await session.translations(from: requests)
                guard !Task.isCancelled, enabled, generation == token else { return }
                // An ASR append may extend an unfinished sentence while translation is in flight.
                // Discard only that stale unit; keep the system session/download sheet alive.
                let requestedIDs = Set(batch.filter { units.contains($0) }.map(\.index))
                let requestedUnits = Dictionary(uniqueKeysWithValues: batch.map { ($0.index, $0) })
                var updates: [String: String] = [:]
                var receivedIDs = Set<Int>()
                for response in responses {
                    guard let id = response.clientIdentifier.flatMap(Int.init), requestedIDs.contains(id),
                          let key = keys[id], let unit = requestedUnits[id],
                          acceptTranslation(response.targetText, for: unit) else { continue }
                    updates[key] = response.targetText
                    receivedIDs.insert(id)
                }
                onResultsChanged?()
                await MacSubtitleTranslationCache.shared.store(updates)
                guard !Task.isCancelled, generation == token else { return }
                // Do not loop forever when an engine returns incomplete output.
                if receivedIDs != requestedIDs { throw CocoaError(.coderReadCorrupt) }
            }
        } catch {
            guard !Task.isCancelled, enabled, generation == token else { return }
            statusKey = "Translation.Failed"
            canRetry = true
        }
    }
}

/// Remains attached to the player, rather than the short-lived subtitle popover.
struct MacSubtitleTranslationHost: View {
    @ObservedObject var model: MacSubtitleTranslation
    var body: some View {
        Group {
            if #available(macOS 15.0, iOS 18.0, *), model.enabled, model.hasSource, model.statusKey != "Translation.SameLanguage" {
                let token = model.generation
                Color.clear
                    .translationTask(source: model.sourceLanguage.map { Locale.Language(identifier: $0) },
                                     target: Locale.Language(identifier: model.targetLanguage)) { session in
                        await model.translate(using: session, token: token)
                    }
                    .id(model.generation)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SubtitleTranslationDisplayControls: View {
    @ObservedObject var model: MacSubtitleTranslation
    var body: some View {
        Picker(platformShellString("SI.DisplayContent"), selection: Binding(get: { model.displayContent }, set: model.setDisplayContent)) {
            ForEach(MacSubtitleTranslation.DisplayContent.allCases, id: \.self) { value in
                Text(platformShellString(value.titleKey)).tag(value)
            }
        }
        if model.displayContent == .bilingual {
            Picker(platformShellString("SI.BilingualOrder"), selection: Binding(get: { model.originalFirst }, set: model.setOriginalFirst)) {
                Text(platformShellString("SI.OriginalFirst")).tag(true)
                Text(platformShellString("SI.TranslationFirst")).tag(false)
            }
        }
    }
}

struct MacSubtitleTranslationControls: View {
    @ObservedObject var model: MacSubtitleTranslation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(platformShellString("Translation.Target"))
                    .frame(width: 100, alignment: .leading)
                Picker(platformShellString("Translation.Target"), selection: Binding(get: { model.targetLanguage }, set: model.setTarget)) {
                    ForEach(Array(Set(model.languages + [model.targetLanguage])).sorted { model.languageName($0) < model.languageName($1) }, id: \.self) { code in
                        Text(model.languageName(code)).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(platformShellString("Translation.Source"))
                    .frame(width: 100, alignment: .leading)
                Picker(platformShellString("Translation.Source"), selection: Binding(get: { model.sourceOverride }, set: model.setSourceOverride)) {
                    Text(platformShellString("Translation.Automatic")).tag("")
                    ForEach(model.languages, id: \.self) { code in
                        Text(model.languageName(code)).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if model.sourceOverride.isEmpty, let detected = model.sourceLanguage {
                Text(String(format: platformShellString("Translation.DetectedFormat"), model.languageName(detected)))
                    .font(.caption).foregroundColor(.secondary)
            }
            if model.enabled {
                Text(model.statusMessage(for: model.statusKey))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.canRetry {
                Button(platformShellString("Retry")) { model.retry() }
            }
        }
        .onAppear {
            if #available(macOS 15.0, iOS 18.0, *) {
                Task { @MainActor in await model.loadLanguages() }
            }
        }
    }
}
#endif
