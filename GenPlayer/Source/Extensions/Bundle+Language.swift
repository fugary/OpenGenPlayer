import Foundation
import ObjectiveC

private var bundleKey: UInt8 = 0

extension Bundle {
    static let supportedAppLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"]
    static let selectableAppLanguages = ["system"] + supportedAppLanguages

    static let activateLanguageSwizzling: Void = {
        object_setClass(Bundle.main, BundleEx.self)
    }()
}

class BundleEx: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let bundle = objc_getAssociatedObject(self, &bundleKey) as? Bundle else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    static func autonymAppLanguageName(for language: String) -> String {
        if language == "system" {
            return NSLocalizedString("System", comment: "")
        }

        switch normalizedAppLanguage(from: language) ?? "en" {
        case "en":
            return "English"
        case "zh-Hans":
            return "简体中文"
        case "zh-Hant":
            return "繁體中文"
        case "ja":
            return "日本語"
        case "ko":
            return "한국어"
        case "fr":
            return "Français"
        case "de":
            return "Deutsch"
        case "es":
            return "Español"
        default:
            return "English"
        }
    }

    static func localizedAppLanguageName(for language: String) -> String {
        if language == "system" {
            return NSLocalizedString("System", comment: "")
        }

        switch normalizedAppLanguage(from: language) ?? "en" {
        case "en":
            return NSLocalizedString("English", comment: "")
        case "zh-Hans":
            return NSLocalizedString("Chinese Simplified", comment: "")
        case "zh-Hant":
            return NSLocalizedString("Chinese Traditional", comment: "")
        case "ja":
            return NSLocalizedString("Japanese", comment: "")
        case "ko":
            return NSLocalizedString("Korean", comment: "")
        case "fr":
            return NSLocalizedString("French", comment: "")
        case "de":
            return NSLocalizedString("German", comment: "")
        case "es":
            return NSLocalizedString("Spanish", comment: "")
        default:
            return NSLocalizedString("English", comment: "")
        }
    }

    static func englishAppLanguageName(for language: String) -> String {
        if language == "system" {
            return "System"
        }

        switch normalizedAppLanguage(from: language) ?? "en" {
        case "en":
            return "English"
        case "zh-Hans":
            return "Chinese (Simplified)"
        case "zh-Hant":
            return "Chinese (Traditional)"
        case "ja":
            return "Japanese"
        case "ko":
            return "Korean"
        case "fr":
            return "French"
        case "de":
            return "German"
        case "es":
            return "Spanish"
        default:
            return "English"
        }
    }

    static func localizedAppLanguageSummary(for language: String) -> String {
        if language == "system" {
            let resolved = autonymAppLanguageName(for: resolvedAppLanguage(for: language))
            return "\(NSLocalizedString("System", comment: "")) · \(resolved)"
        }

        return autonymAppLanguageName(for: language)
    }

    static func pickerPrimaryAppLanguageName(for language: String) -> String {
        if language == "system" {
            return NSLocalizedString("System", comment: "")
        }

        return autonymAppLanguageName(for: language)
    }

    static func pickerSecondaryAppLanguageName(for language: String) -> String? {
        if language == "system" {
            return autonymAppLanguageName(for: resolvedAppLanguage(for: language))
        }

        let autonym = autonymAppLanguageName(for: language)
        let localized = localizedAppLanguageName(for: language)
        if autonym != localized {
            return localized
        }

        let english = englishAppLanguageName(for: language)
        return autonym == english ? nil : english
    }

    static func resolvedAppLanguage(for language: String, preferredLanguages: [String]? = nil) -> String {
        if language != "system" {
            return normalizedAppLanguage(from: language) ?? "en"
        }

        let candidates = preferredLanguages ?? systemPreferredLanguages()

        for preferred in candidates {
            if let normalized = normalizedAppLanguage(from: preferred) {
                return normalized
            }
        }

        return "en"
    }

    static func systemLanguageIdentifier() -> String {
        systemPreferredLanguages().first ?? Locale.autoupdatingCurrent.identifier
    }

    static func setLanguage(_ language: String) {
        _ = Bundle.activateLanguageSwizzling

        let targetLang = resolvedAppLanguage(for: language)

        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([targetLang], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        
        // Robust Search Strategy: List all lproj bundles and match
        var matchedBundle: Bundle? = nil
        
        // Clean up targetLang (preferredLocalizations might return "zh-Hans-CN" or just "zh-Hans")
        // We match fuzzily below.
        
        let searchDirectories: [String?] = [nil, "Resources"]
        let potentialNames = [targetLang,
                              targetLang.replacingOccurrences(of: "-", with: "_"),
                              targetLang.replacingOccurrences(of: "_", with: "-")]

        // Keep the script-specific bundle match stable so Traditional Chinese
        // never falls through to the Simplified Chinese resources.
        var allTargets = potentialNames
        switch targetLang {
        case "zh-Hant":
            allTargets.append(contentsOf: ["zh-TW", "zh_TW", "zh-HK", "zh_HK", "zh-MO", "zh_MO", "zh"])
        case "zh-Hans":
            allTargets.append(contentsOf: ["zh-CN", "zh_CN", "zh-SG", "zh_SG", "zh"])
        default:
            if targetLang.hasPrefix("en") {
                allTargets.append(contentsOf: ["en", "en-US", "Base"])
            }
        }
        
        outerLoop: for subdir in searchDirectories {
            if let urls = Bundle.main.urls(forResourcesWithExtension: "lproj", subdirectory: subdir) {
                for url in urls {
                    let folderName = url.deletingPathExtension().lastPathComponent
                    if allTargets.contains(folderName) {
                        if let b = Bundle(url: url) {
                            matchedBundle = b
                            break outerLoop
                        }
                    }
                }
            }
        }
        
        if let bundle = matchedBundle {
            objc_setAssociatedObject(Bundle.main, &bundleKey, bundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if language == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([targetLang], forKey: "AppleLanguages")
            }
            UserDefaults.standard.synchronize()
        } else {
            // Don't clear association, keep previous; OR set to nil to use system default
            // objc_setAssociatedObject(Bundle.main, &bundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private static func normalizedAppLanguage(from identifier: String) -> String? {
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

        for language in supportedAppLanguages where !language.hasPrefix("zh") {
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

        if let languages = UserDefaults(suiteName: UserDefaults.globalDomain)?.array(forKey: "AppleLanguages") as? [String],
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
