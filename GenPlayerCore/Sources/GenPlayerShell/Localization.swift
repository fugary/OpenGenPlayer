import Foundation
import SwiftUI
import GenPlayerCore

private let _setupMediaCountFormatter: Void = {
    MediaCountFormatter.customLocalizer = { platformShellString($0) }
    DownloadFileValidation.localize = { platformShellString($0) }
}()

public func platformShellString(_ key: String) -> String {
    _ = _setupMediaCountFormatter
    if let moduleValue = PlatformShellLocalization.localizedString(key, in: .module) {
        return moduleValue
    }

    if let mainValue = PlatformShellLocalization.localizedString(key, in: .main) {
        return mainValue
    }

    return NSLocalizedString(key, bundle: .module, comment: "")
}

public func platformShellText(_ key: String) -> Text {
    Text(platformShellString(key))
}

public func platformResolvedLanguage(for language: String) -> String {
    PlatformShellLocalization.resolvedLanguage(for: language)
}

private enum PlatformShellLocalization {
    private static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"]

    static func localizedString(_ key: String, in bundle: Bundle) -> String? {
        let storedLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let language = resolvedLanguage(for: storedLanguage)

        let sentinel = "\u{0001}\u{0002}\u{0003}"
        for candidate in bundleCandidates(for: language) {
            guard
                let url = bundle.url(forResource: candidate, withExtension: "lproj"),
                let localizedBundle = Bundle(url: url)
            else {
                continue
            }

            let value = localizedBundle.localizedString(forKey: key, value: sentinel, table: nil)
            if value != sentinel {
                return value
            }
        }

        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    fileprivate static func resolvedLanguage(for language: String) -> String {
        if language != "system" {
            return normalizedLanguage(from: language) ?? "en"
        }

        for preferred in systemPreferredLanguages() {
            if let normalized = normalizedLanguage(from: preferred) {
                return normalized
            }
        }

        return "en"
    }

    private static func bundleCandidates(for language: String) -> [String] {
        switch language {
        case "zh-Hant":
            return ["zh-Hant", "zh-Hant-TW", "zh-TW", "zh-HK", "zh"]
        case "zh-Hans":
            return ["zh-Hans", "zh-Hans-CN", "zh-CN", "zh"]
        case "en":
            return ["en", "Base"]
        default:
            return [language]
        }
    }

    private static func normalizedLanguage(from identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()

        if normalized.hasPrefix("zh") {
            if normalized.contains("hant") || normalized.contains("tw") || normalized.contains("hk") || normalized.contains("mo") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }

        if normalized.hasPrefix("en") {
            return "en"
        }

        for language in supportedLanguages where !language.hasPrefix("zh") {
            let lowercased = language.lowercased()
            if normalized == lowercased || normalized.hasPrefix(lowercased + "-") {
                return language
            }
        }

        return nil
    }

    private static func systemPreferredLanguages() -> [String] {
        if let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String],
           !languages.isEmpty {
            return languages
        }

        if let languages = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String], !languages.isEmpty {
            return languages
        }

        let identifier = Locale.autoupdatingCurrent.identifier
        if !identifier.isEmpty {
            return [identifier]
        }

        return Locale.preferredLanguages
    }
}

#if os(macOS)
import AppKit

public func relaunchMacApp() {
    let url = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
#endif
