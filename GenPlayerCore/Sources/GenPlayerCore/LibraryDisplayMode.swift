import Foundation

public enum LibraryDisplayMode: String, CaseIterable, Identifiable {
    case poster = "poster"
    case thumb = "thumb"
    case list = "list"

    public var id: String { rawValue }

    public var localizedTitleKey: String {
        switch self {
        case .poster:
            return "Poster"
        case .thumb:
            return "Thumb"
        case .list:
            return "List"
        }
    }

    public var localizedTitle: String {
        switch self {
        case .poster:
            return NSLocalizedString("Poster", comment: "Poster view mode")
        case .thumb:
            return NSLocalizedString("Thumb", comment: "Thumb view mode")
        case .list:
            return NSLocalizedString("List", comment: "List view mode")
        }
    }

    public var iconName: String {
        switch self {
        case .poster:
            return "square.grid.2x2"
        case .thumb:
            return "rectangle.grid.2x2"
        case .list:
            return "list.bullet"
        }
    }
}
