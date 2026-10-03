#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
import CryptoKit

public struct MacMPVTrack: Equatable {
    public let id: Int
    public let type: String
    public let title: String
    public let language: String
    public let codec: String
    public let external: Bool
    public var externalFilename: String = ""
    public var sourceID: UInt64? = nil

    public var externalURL: URL? {
        guard external, !externalFilename.isEmpty else { return nil }
        if externalFilename.hasPrefix("/") { return URL(fileURLWithPath: externalFilename) }
        guard let url = URL(string: externalFilename), ["file", "http", "https", "smb", "ftp", "ftps", "sftp", "nfs"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Display metadata must never fall back to an authenticated request URL.
    /// Keep track identity and its real source URL untouched.
    public func subtitleDisplayName(preferredTitle: String? = nil, fallback: String) -> String {
        func clean(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = trimmed.removingPercentEncoding ?? trimmed
            let path = decoded.components(separatedBy: "?").first?.components(separatedBy: "#").first ?? ""
            if path.contains("://") {
                guard let url = URL(string: path) else { return "" }
                return url.lastPathComponent == "/" ? "" : url.lastPathComponent
            }
            return path.hasPrefix("/") ? (path as NSString).lastPathComponent : path
        }
        let preferred = clean(preferredTitle ?? "")
        let rawTitle = clean(title)
        let generic = ["stream", "subtitle", "subtitles"]
        let stem = (rawTitle as NSString).deletingPathExtension.lowercased()
        let displayTitle = !preferred.isEmpty ? preferred : (rawTitle.isEmpty || generic.contains(stem) ? fallback : rawTitle)
        var components = [displayTitle]
        for detail in [language, codec] {
            let value = clean(detail)
            if !value.isEmpty && !displayTitle.localizedCaseInsensitiveContains(value) { components.append(value) }
        }
        return components.joined(separator: " · ")
    }

    public var isBitmap: Bool {
        ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"].contains(codec.lowercased())
    }
}

/// Preferences contain semantic track identity, never an mpv/VLC numeric ID or credentials.
public struct MacMPVTrackChoice: Codable, Equatable {
    struct Signature: Codable, Equatable {
        let title: String
        let language: String
        let codec: String
        let external: Bool
        let source: String?
        init(_ track: MacMPVTrack) {
            title = Self.safeTitle(track.title, external: track.external); language = track.language; codec = track.codec; external = track.external
            source = track.externalURL.map { MacMPVTrackChoice.mediaKey(url: $0) }
        }

        private static func safeTitle(_ title: String, external: Bool) -> String {
            guard external else { return title }
            let decoded = title.removingPercentEncoding ?? title
            let path = decoded.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
            if path.contains("://") {
                return URL(string: path)?.lastPathComponent ?? ""
            }
            return (path as NSString).lastPathComponent
        }

        private enum CodingKeys: String, CodingKey { case title, language, codec, external, source }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            external = try values.decode(Bool.self, forKey: .external)
            title = Self.safeTitle(try values.decode(String.self, forKey: .title), external: external)
            language = try values.decode(String.self, forKey: .language)
            codec = try values.decode(String.self, forKey: .codec)
            source = try values.decodeIfPresent(String.self, forKey: .source)
        }
    }
    let signature: Signature? // nil means explicitly off
    let occurrence: Int
    let matchCount: Int

    /// Rewrite only this feature's stored dictionaries, including inherited iOS choices.
    /// Decoding normalizes old URL-derived titles; unrelated preferences are untouched.
    public static func sanitizeStoredPreferences(in defaults: UserDefaults = .standard) {
        let prefixes = ["macMPVTrackChoice.", "ios.macMPVTrackChoice.", "tv.macMPVTrackChoice.", "ios.mpv.trackScope."]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (key, value) in defaults.dictionaryRepresentation() where prefixes.contains(where: key.hasPrefix) {
            guard let data = value as? Data else { continue }
            guard let choices = try? JSONDecoder().decode([String: Self].self, from: data),
                  let clean = try? encoder.encode(choices) else {
                defaults.removeObject(forKey: key)
                continue
            }
            if clean != data { defaults.set(clean, forKey: key) }
        }
    }

    public static func selected(_ id: Int, in tracks: [MacMPVTrack]) -> Self? {
        if id < 0 { return Self(signature: nil, occurrence: 0, matchCount: 0) }
        guard let track = tracks.first(where: { $0.id == id }) else { return nil }
        let signature = Signature(track)
        let matches = tracks.filter { Signature($0) == signature }
        guard let occurrence = matches.firstIndex(where: { $0.id == id }) else { return nil }
        return Self(signature: signature, occurrence: occurrence, matchCount: matches.count)
    }

    public func resolve(in tracks: [MacMPVTrack]) -> Int? {
        guard let signature else { return -1 }
        let matches = tracks.filter { Signature($0) == signature }
        guard matches.count == matchCount, matches.indices.contains(occurrence) else { return nil }
        return matches[occurrence].id
    }

    /// Migrate a saved server download to its verified embedded track. Source
    /// identity is required; matching language/title alone can select another track.
    public func resolveExternalAlias(_ aliases: [URL: Int]) -> Int? {
        guard let signature, signature.external, let source = signature.source,
              occurrence == 0, matchCount == 1 else { return nil }
        let ids = Set(aliases.filter { Self.mediaKey(url: $0.key) == source }.map(\.value))
        return ids.count == 1 ? ids.first : nil
    }

    public static func mediaKey(url: URL, serverID: String? = nil, itemID: String? = nil, path: String? = nil) -> String {
        let identity: String
        if let serverID, let itemID, !itemID.isEmpty {
            identity = "server|\(serverID)|item|\(itemID)"
        } else if let serverID, let path, !path.isEmpty {
            identity = "server|\(serverID)|path|\(path)"
        } else if url.isFileURL {
            identity = url.standardizedFileURL.path
        } else {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.user = nil; components?.password = nil; components?.fragment = nil
            // Keep content selectors (e.g. ?id=episode), but discard rotating credentials.
            let secrets = Set(["api_key", "token", "access_token", "auth", "signature", "sig", "expires",
                               "x-plex-token", "x-emby-token", "x-mediabrowser-token"])
            let query = components?.queryItems?.filter {
                !secrets.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("x-amz-")
            }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            components?.queryItems = query?.isEmpty == false ? query : nil
            identity = components?.string ?? url.path
        }
        return "macMPVTrackChoice." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
/// Verify container order before independently extracting text; sidecars never count.
public enum MacMPVSubtitleMapping {
    public static func ordinal(selectedID: Int, tracks: [MacMPVTrack],
                        descriptors: [(codec: String?, language: String?, title: String?)]) -> Int? {
        let embedded = tracks.filter { $0.type == "sub" && !$0.external }
        guard embedded.count == descriptors.count, Set(embedded.map(\.id)).count == embedded.count,
              let index = embedded.firstIndex(where: { $0.id == selectedID }) else { return nil }
        for (track, descriptor) in zip(embedded, descriptors) {
            if let codec = descriptor.codec, !codec.isEmpty, !track.codec.isEmpty,
               normalizedCodec(codec) != normalizedCodec(track.codec) { return nil }
            if let language = descriptor.language, !language.isEmpty, !track.language.isEmpty,
               language != "und", track.language != "und",
               normalizedLanguage(language) != normalizedLanguage(track.language) { return nil }
            if let title = descriptor.title, !title.isEmpty, !track.title.isEmpty, title != track.title { return nil }
        }
        return index
    }

    private static func normalizedCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "srt", "subrip", "s_text/utf8": return "subrip"
        case "ass", "ssa", "s_text/ass", "s_text/ssa": return "ass"
        case "vtt", "webvtt": return "webvtt"
        case "pgs", "hdmv_pgs_subtitle": return "pgs"
        case "dvd_subtitle", "dvdsub": return "dvdsub"
        default: return codec.lowercased()
        }
    }

    private static func normalizedLanguage(_ language: String) -> String {
        let code = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        return ["zh": "zho", "chi": "zho", "en": "eng", "ja": "jpn", "ko": "kor",
                "fr": "fra", "fre": "fra", "de": "deu", "ger": "deu", "es": "spa" ][code] ?? code
    }
}
#endif

#if os(macOS) || os(iOS) || os(tvOS)
/// Match the original audio ordinal for the independent audio extraction worker.
/// Playback and extraction numeric IDs are unrelated, including within one MKV.
enum MacMPVAudioMapping {
    static func remuxSelection(selectedID: Int, tracks: [MacMPVTrack],
                               source: [(id: Int, ordinal: Int)]) -> Int? {
        let internalAudio = tracks.filter { $0.type == "audio" && !$0.external }
        guard !source.isEmpty, internalAudio.count == source.count,
              Set(internalAudio.map(\.id)).count == internalAudio.count,
              Set(source.map(\.id)).count == source.count,
              Set(source.map(\.ordinal)) == Set(1...source.count),
              let index = internalAudio.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return source.first { $0.ordinal == index + 1 }?.id
    }
}
#endif

#if os(macOS) || os(iOS) || os(tvOS)
/// Missing/ambiguous media versions must not silently become the first server version.
enum MacMPVMediaSourceSelection {
    static func index(requestedID: String?, sourceIDs: [String?]) -> Int? {
        guard let requestedID, !requestedID.isEmpty else { return sourceIDs.count == 1 ? 0 : nil }
        let matches = sourceIDs.indices.filter { sourceIDs[$0] == requestedID }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum MacMPVSubtitleSelection {
    static func operations(primary: Int, secondary: Int) -> [(String, String)] {
        // A shared decoder owns only the primary slot. ASS mirrors in the native
        // bridge; ordinary text mirrors through the app timeline.
        let nativeSecondary = secondary == primary ? -1 : secondary
        return [("secondary-sid", "no"), ("sid", primary < 0 ? "no" : String(primary)),
                ("secondary-sid", nativeSecondary < 0 ? "no" : String(nativeSecondary))]
    }
}
#endif
