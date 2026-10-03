#if os(iOS) || os(macOS)
import Foundation
import GenPlayerCore

extension SubtitleBrowserSource {
    static func generated(id: String, title: String, offset: Double, audio: MacAudioSubtitleJob,
                          translation: MacSubtitleTranslation, original: Bool, translated: Bool) -> Self {
        Self(id: id, title: title,
             revision: "\(audio.browserRevision)|\(translation.browserRevision)|\(original)|\(translated)|\(translation.originalFirst)",
             offset: offset) {
            let parts = translated ? translation.browserParts(content: original ? .bilingual : .translated)
                : audio.cues.map { SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text)) }
            return SubtitleBrowserDocument(parts: parts, isPartial: audio.cache?.isComplete != true ||
                                           (translated && translation.browserTranslationIsPartial))
        }
    }

    static func translated(id: String, title: String, offset: Double, translation: MacSubtitleTranslation) -> Self {
        Self(id: id, title: title, revision: "\(translation.browserRevision)", offset: offset) {
            SubtitleBrowserDocument(parts: translation.browserParts(content: .translated),
                                    isPartial: translation.browserTranslationIsPartial)
        }
    }
}

#if os(iOS)
extension IOSSubtitleIntelligence {
    public func browserSource(primary: Bool, sessionID: String, offset: Double) -> SubtitleBrowserSource? {
        let destination: MacAudioSubtitleJob.Destination = primary ? .primary : .secondary
        let title = platformShellString(primary ? "Primary" : "Secondary")
        let id = "\(sessionID)|\(primary ? "primary" : "secondary")"
        if audio.uses(destination) {
            return .generated(id: id + "|generated", title: title, offset: offset, audio: audio, translation: translation,
                original: audio.activeOriginalDestination == destination,
                translated: audio.activeTranslationDestination == destination)
        }
        if !primary, secondaryID == Self.translatedSecondaryID {
            let partial = primarySourceIsPartial
            return SubtitleBrowserSource(id: id + "|translation", title: title,
                revision: "\(translation.browserRevision)|\(partial)", offset: offset) {
                SubtitleBrowserDocument(parts: self.translation.browserParts(content: .translated),
                    isPartial: partial || self.translation.browserTranslationIsPartial)
            }
        }
        return nil
    }
}
#endif
#endif
