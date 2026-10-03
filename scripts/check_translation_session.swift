import Foundation
import GenPlayerCore

// The UI localization shell is not needed for model identity checks.
func platformShellString(_ key: String) -> String { key }
func platformResolvedLanguage(for value: String) -> String { "en" }

@main struct TranslationSessionChecks {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
            print("PASS: \(message)")
        }
        let suite = "TranslationPreferenceChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fr", forKey: "macSubtitleTranslationTargetLanguage")
        let a = MacSubtitleTranslationPreference.key(provider: "jellyfin", serverID: "SERVER", itemID: "A", url: URL(string: "https://example.invalid/a")!)
        let b = MacSubtitleTranslationPreference.key(provider: "jellyfin", serverID: "SERVER", itemID: "B", url: URL(string: "https://example.invalid/b")!)
        let preference = MacSubtitleTranslation(defaults: defaults)
        preference.bindPreference(key: a)
        check(preference.targetLanguage == "fr", "existing global target migrates as first-use default")
        preference.bindPreference(key: b)
        preference.setTarget("ja")
        preference.bindPreference(key: a)
        check(preference.targetLanguage == "fr", "first-use target remains independent after another video's change")
        preference.setTarget("zh-Hans")
        preference.setEnabled(false)
        preference.setEnabled(true)
        check(preference.targetLanguage == "zh-Hans", "turning translation off and on retains the media target")
        let reopened = MacSubtitleTranslation(defaults: defaults)
        reopened.bindPreference(key: b)
        check(reopened.targetLanguage == "ja", "new player restores this video's saved target")
        reopened.bindPreference(key: a)
        check(reopened.targetLanguage == "zh-Hans", "switching videos restores their own target")
        let sameItem = MacSubtitleTranslationPreference.key(provider: "jellyfin", serverID: "server", itemID: "A", url: URL(string: "https://example.invalid/new?token=changed")!)
        check(sameItem == a, "server media target identity survives refreshed playback URL")
        MacSubtitleTranslationPreference.save(true, key: a, defaults: defaults)
        reopened.setTarget("de")
        check(MacSubtitleTranslationPreference.isEnabled(key: a, defaults: defaults), "target changes preserve the existing per-media enabled preference")
        let model = MacSubtitleTranslation()
        model.setEnabled(true)
        let first = MacAudioSubtitleCue(id: 0, start: 0, end: 1, text: "こんにちは")
        let next = MacAudioSubtitleCue(id: 10000, start: 30, end: 31, text: "ありがとうございます")
        model.followGenerated(key: "source", language: "ja", cues: [first])
        let downloadingSession = model.generation
        let preparingStatus = model.statusKey
        check(model.hasSource && model.sourceLanguage == "ja", "first ASR chunk establishes a source")
        model.followGenerated(key: "source", language: "ja", cues: [first, next])
        check(model.generation == downloadingSession, "new ASR chunks preserve the download session identity")
        check(model.statusKey == preparingStatus, "appending a chunk preserves preparation state")
        model.playbackTime = 30
        model.followGenerated(key: "source", language: "ja", cues: [first, next])
        check(model.generation == downloadingSession, "playback progress and repeated results do not restart translation")
        model.setSourceOverride("fr")
        let overrideSession = model.generation
        check(overrideSession != downloadingSession && model.sourceLanguage == "fr", "explicit language change invalidates the old session")
        model.followGenerated(key: "source", language: "ja", cues: [first, next,
            .init(id: 20000, start: 60, end: 61, text: "さようなら")])
        check(model.generation == overrideSession && model.sourceLanguage == "fr", "append respects the manual source language")
        model.retry()
        check(model.generation != overrideSession, "explicit retry starts a new session")
        let retriedSession = model.generation
        model.followGenerated(key: "source", language: "ja", cues: [first, next])
        check(model.generation == retriedSession, "source refresh does not undo the retry identity")
        model.followGenerated(key: "other", language: "ja", cues: [first])
        check(model.generation != retriedSession && model.sourceOverride.isEmpty, "changing media invalidates the old session and override")
        model.setEnabled(false)
        let disabled = model.generation
        model.followGenerated(key: "other", language: "ja", cues: [first, next])
        check(!model.hasSource && model.generation == disabled, "late chunks cannot reopen a disabled translation")
        model.setEnabled(true)
        model.followGenerated(key: "empty", language: "ja", cues: [])
        let empty = model.generation
        model.followGenerated(key: "empty", language: "ja", cues: [first])
        check(model.hasSource && model.generation == empty, "first nonempty chunk enables the existing source")
        func cue(_ index: Int, _ start: Double, _ end: Double, _ text: String) -> MacSubtitleTranslationCue {
            .init(index: index, start: start, end: end, text: text)
        }
        let fragment = cue(0, 0, 2, "I wanted to tell you")
        let continuation = cue(1, 2.1, 4, "that I am sorry.")
        let joined = MacSubtitleTranslationPlan.units(cues: [fragment, continuation])
        check(joined.count == 1 && joined[0].text == "I wanted to tell you that I am sorry.", "unfinished adjacent sentence joins before translation")
        check(MacSubtitleTranslationPlan.batch(units: joined, at: 3, translated: []).first == joined.first, "seek into second fragment translates the whole sentence")
        check(MacSubtitleTranslationPlan.batch(units: joined, at: 4, translated: []).isEmpty, "finished units are not scheduled")
        check(MacSubtitleTranslationPlan.batch(units: joined, at: 1, translated: [0]).isEmpty, "cached whole units are skipped")
        for ending in ["Done.", "Done?", "Done!", "完成。", "待って…"] {
            check(MacSubtitleTranslationPlan.units(cues: [cue(0, 0, 2, ending), continuation]).count == 2, "sentence ending prevents merging: \(ending)")
        }
        for marked in ["- that I am sorry", "Alice: that I am sorry", "♪ that I am sorry ♪", "# that I am sorry #", "[whispers] that I am sorry", "hello\n— Goodbye"] {
            check(MacSubtitleTranslationPlan.units(cues: [fragment, cue(1, 2.1, 4, marked)]).count == 2, "speaker/caption/song boundary stays separate: \(marked)")
        }
        check(MacSubtitleTranslationPlan.units(cues: [fragment, cue(1, 2.5, 4, "that I am sorry")]).count == 2, "pause prevents merging")
        check(MacSubtitleTranslationPlan.units(cues: [fragment, cue(1, 1.5, 4, "that I am sorry")]).count == 2, "overlapping speakers stay separate")
        check(MacSubtitleTranslationPlan.units(cues: [fragment, cue(1, 2.1, 4, "Thank you")]).count == 2, "uncertain capitalized new utterance stays separate")
        check(MacSubtitleTranslationPlan.units(cues: [cue(0, 0, 2, "如果你愿意，"), cue(1, 2.1, 4, "我们就出发。")]).count == 1, "comma continuation supports CJK")
        check(MacSubtitleTranslationPlan.units(cues: [fragment, cue(1, 2.1, 9, "that I am sorry")]).count == 2, "long merged display duration is bounded")
        check(MacSubtitleTranslationPlan.units(cues: [fragment, cue(1, 2.1, 4, String(repeating: "a", count: 180))]).count == 2, "merged character count is bounded")
        let four = (0..<4).map { cue($0, Double($0), Double($0 + 1), "continued") }
        check(MacSubtitleTranslationPlan.units(cues: four).map { $0.members.count } == [3, 1], "at most three fragments merge")
        check(MacSubtitleTranslationPlan.cacheKey(text: joined[0].text, source: "en", target: "zh-Hans") != MacSubtitleTranslationPlan.cacheKey(text: fragment.text, source: "en", target: "zh-Hans"), "whole source text differentiates joined cache")

        let incremental = MacSubtitleTranslation()
        incremental.setEnabled(true)
        func audio(_ cue: MacSubtitleTranslationCue) -> MacAudioSubtitleCue {
            .init(id: cue.index, start: cue.start, end: cue.end, text: cue.text)
        }
        incremental.followGenerated(key: "incremental", language: "en", cues: [audio(fragment)])
        let oldUnit = MacSubtitleTranslationPlan.units(cues: [fragment])[0]
        check(incremental.acceptTranslation("旧译文", for: oldUnit), "initial standalone result accepted")
        let sameSession = incremental.generation
        incremental.followGenerated(key: "incremental", language: "en", cues: [audio(fragment), audio(continuation)])
        check(incremental.generation == sameSession, "regrouping does not recreate the download session")
        check(incremental.activeParts(at: 1).isEmpty, "extending a sentence invalidates its old translation")
        check(!incremental.acceptTranslation("晚到的旧译文", for: oldUnit), "in-flight standalone result cannot overwrite a joined sentence")
        check(incremental.acceptTranslation("我想告诉你，我很抱歉。", for: joined[0]), "current joined result accepted")
        check(incremental.activeParts(at: 1).first?.end == 2 && incremental.activeParts(at: 3).first?.start == 2.1, "joined translation keeps original cue intervals")
        check(incremental.activeParts(at: 2.05).isEmpty, "joined translation preserves the original silent gap")
        let separate = cue(2, 6, 7, "Goodbye.")
        incremental.followGenerated(key: "incremental", language: "en", cues: [audio(fragment), audio(continuation), audio(separate)])
        check(!incremental.activeParts(at: 3).isEmpty, "unrelated append preserves translated units")
        incremental.setEnabled(false)
        check(!incremental.acceptTranslation("旧结果", for: joined[0]), "disabled source rejects old units")
        let bilingual = MacSubtitleTranslation(defaults: defaults)
        bilingual.setEnabled(true)
        bilingual.followGenerated(key: "bilingual", language: "en", cues: [audio(fragment), audio(continuation)])
        let bilingualSession = bilingual.generation
        bilingual.setDisplayContent(.bilingual)
        check(bilingual.activeParts(at: 1).first?.text?.string == joined[0].text + "\n ", "bilingual mode keeps original while translation waits")
        check(bilingual.acceptTranslation("合句译文", for: joined[0]), "bilingual result accepted")
        check(bilingual.activeParts(at: 3).first?.text?.string == joined[0].text + "\n合句译文", "original and translation use the same joined unit")
        check(bilingual.activeParts(at: 2.05).isEmpty && bilingual.activeParts(at: 4).isEmpty, "bilingual output preserves silence and does not display expired results")
        bilingual.setOriginalFirst(false)
        check(bilingual.activeParts(at: 1).first?.text?.string == "合句译文\n" + joined[0].text, "bilingual order can be reversed")
        bilingual.setDisplayContent(.original)
        check(bilingual.activeParts(at: 1).first?.text?.string == joined[0].text, "original-only hides translation")
        check(bilingual.activeParts(at: 1, content: .translated).first?.text?.string == "合句译文", "primary translation ignores legacy original-only display preference")
        bilingual.setDisplayContent(.translated)
        check(bilingual.activeParts(at: 1).first?.text?.string == "合句译文" && bilingual.generation == bilingualSession, "display choices reuse the existing translation session and results")
        bilingual.setDisplayContent(.bilingual)
        let displayRestored = MacSubtitleTranslation(defaults: defaults)
        check(displayRestored.displayContent == .bilingual && !displayRestored.originalFirst, "new player remembers display mode and order")
        let browserSession = bilingual.generation
        let browserRevision = bilingual.browserRevision
        let browserParts = bilingual.browserParts(content: .translated)
        check(browserParts.count == 2 && browserParts[0].end == 2 && browserParts[1].start == 2.1,
              "browser snapshot preserves source cue boundaries and silent gaps")
        check(browserParts.allSatisfy { $0.text?.string == "合句译文" }, "browser exposes existing translation without status placeholders")
        check(!bilingual.browserTranslationIsPartial && bilingual.generation == browserSession && bilingual.browserRevision == browserRevision,
              "read-only browser snapshot does not schedule or invalidate translation")
        bilingual.setTarget("es")
        check(bilingual.activeParts(at: 1).first?.text?.string == " \n" + joined[0].text, "changing target removes old translation but preserves original")
        check(bilingual.browserParts(content: .translated).isEmpty && bilingual.browserTranslationIsPartial,
              "target change retracts stale translation from browser")
        check(bilingual.browserRevision != browserRevision, "translation reset invalidates browser snapshot")
        print("PASS: \(checks) translation session checks")
    }
}
