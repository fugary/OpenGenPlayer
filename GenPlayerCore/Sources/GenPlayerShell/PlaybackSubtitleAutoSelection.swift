import Foundation

/// Application preference, independent of native default/forced track ranking.
/// Callers apply it once, only after explicit selections and restoration have resolved.
public enum PlaybackSubtitleAutoSelection {
    public static func index(in names: [String], mode: String, language: String) -> Int? {
        guard ["followAppLanguage", "chinese", "english"].contains(mode) else { return nil }
        let code = mode == "chinese" ? "zh" : mode == "english" ? "en"
            : language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let tokens: [String]
        switch code {
        case "zh": tokens = ["中文", "中字", "简中", "繁中", "简体", "繁体", "chinese", "mandarin", "zh", "zho", "chi", "chs", "cht"]
        case "en": tokens = ["英文", "英字", "english", "eng", "en"]
        case "ja": tokens = ["日语", "日文", "日本語", "japanese", "jpn", "ja"]
        case "ko": tokens = ["韩语", "韩文", "한국어", "korean", "kor", "ko"]
        case "fr": tokens = ["法语", "法文", "français", "french", "fra", "fre", "fr"]
        case "de": tokens = ["德语", "德文", "deutsch", "german", "deu", "ger", "de"]
        case "es": tokens = ["西班牙语", "español", "spanish", "spa", "es"]
        default: tokens = []
        }
        if let index = names.firstIndex(where: { name in
            let lowered = name.lowercased()
            let words = Set(lowered.components(separatedBy: CharacterSet.alphanumerics.inverted))
            return tokens.contains { token in
                if token.canBeConverted(to: .ascii), token.count <= 3 { return words.contains(token) }
                return lowered.contains(token)
            }
        }) { return index }
        // Preserve the existing single-track fallback. Multiple unmatched tracks
        // remain under native default selection; do not guess the first track.
        return names.count == 1 ? 0 : nil
    }
}
