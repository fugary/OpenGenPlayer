import Foundation

public struct MediaCountFormatter {
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    public static func formatCount(_ count: Int) -> String {
        return numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    public static var customLocalizer: ((String) -> String)? = nil

    public static func localized(_ key: String) -> String {
        if let custom = customLocalizer {
            return custom(key)
        }
        return NSLocalizedString(key, comment: "")
    }

    public static func format(count: Int, libraryType: JellyfinLibrary.LibraryType) -> String {
        let formattedNumber = formatCount(count)
        if count == 1 {
            switch libraryType {
            case .movies:
                return String(format: localized("%@ Movie"), formattedNumber)
            case .tvShows:
                return String(format: localized("%@ TV Show"), formattedNumber)
            case .music:
                return String(format: localized("%@ Song"), formattedNumber)
            case .photos:
                return String(format: localized("%@ Photo"), formattedNumber)
            case .collections:
                return String(format: localized("%@ Collection"), formattedNumber)
            case .playlists:
                return String(format: localized("%@ Playlist"), formattedNumber)
            case .mixed:
                return String(format: localized("%@ Item"), formattedNumber)
            }
        }
        switch libraryType {
        case .movies:
            return String(format: localized("%@ Movies"), formattedNumber)
        case .tvShows:
            return String(format: localized("%@ TV Shows"), formattedNumber)
        case .music:
            return String(format: localized("%@ Songs"), formattedNumber)
        case .photos:
            return String(format: localized("%@ Photos"), formattedNumber)
        case .collections:
            return String(format: localized("%@ Collections"), formattedNumber)
        case .playlists:
            return String(format: localized("%@ Playlists"), formattedNumber)
        case .mixed:
            return String(format: localized("%@ Items"), formattedNumber)
        }
    }

    public static func formatTotal(count: Int, libraryType: JellyfinLibrary.LibraryType) -> String {
        let formattedNumber = formatCount(count)
        switch libraryType {
        case .movies:
            return String(format: localized("Total %@ Movies"), formattedNumber)
        case .tvShows:
            return String(format: localized("Total %@ TV Shows"), formattedNumber)
        case .music:
            return String(format: localized("Total %@ Songs"), formattedNumber)
        case .photos:
            return String(format: localized("Total %@ Photos"), formattedNumber)
        case .collections:
            return String(format: localized("Total %@ Collections"), formattedNumber)
        case .playlists:
            return String(format: localized("Total %@ Playlists"), formattedNumber)
        case .mixed:
            return String(format: localized("Total %@ Items"), formattedNumber)
        }
    }

    public static func format(count: Int, libraryType: EmbyLibrary.LibraryType) -> String {
        let jellyfinType: JellyfinLibrary.LibraryType
        switch libraryType {
        case .movies: jellyfinType = .movies
        case .tvShows: jellyfinType = .tvShows
        case .music: jellyfinType = .music
        case .photos: jellyfinType = .photos
        case .collections: jellyfinType = .collections
        case .playlists: jellyfinType = .playlists
        case .mixed: jellyfinType = .mixed
        }
        return format(count: count, libraryType: jellyfinType)
    }

    public static func formatTotal(count: Int, libraryType: EmbyLibrary.LibraryType) -> String {
        let jellyfinType: JellyfinLibrary.LibraryType
        switch libraryType {
        case .movies: jellyfinType = .movies
        case .tvShows: jellyfinType = .tvShows
        case .music: jellyfinType = .music
        case .photos: jellyfinType = .photos
        case .collections: jellyfinType = .collections
        case .playlists: jellyfinType = .playlists
        case .mixed: jellyfinType = .mixed
        }
        return formatTotal(count: count, libraryType: jellyfinType)
    }
}

public struct AppRelativeDateTimeFormatter {
    public static func currentAppLocale() -> Locale {
        let storedLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if storedLanguage != "system" {
            return Locale(identifier: storedLanguage)
        }
        if let preferred = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first {
            return Locale(identifier: preferred)
        }
        if let preferred = Locale.preferredLanguages.first {
            return Locale(identifier: preferred)
        }
        return Locale.autoupdatingCurrent
    }

    public static func formatRelativeDate(_ date: Date, relativeTo now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        // If accessed within 60 seconds (or slight sub-second/clock drift in future up to 15 seconds)
        if elapsed > -15 && elapsed < 60 {
            return MediaCountFormatter.localized("Just now")
        }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = currentAppLocale()
        formatter.unitsStyle = .short
        let effectiveDate = elapsed < -15 ? now : date
        return formatter.localizedString(for: effectiveDate, relativeTo: now)
    }
}
