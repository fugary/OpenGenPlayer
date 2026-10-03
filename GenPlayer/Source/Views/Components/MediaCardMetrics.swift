import SwiftUI

enum MediaCardMetrics {
    static let posterWidth: CGFloat = 120
    static let posterHeight: CGFloat = 180
    static let posterTextHeight: CGFloat = 58
    static let peoplePosterWidth: CGFloat = 100
    static let peoplePosterHeight: CGFloat = 150
    static let peopleTextHeight: CGFloat = 58
    static let compactPosterWidth: CGFloat = 112
    static let compactGridSpacing: CGFloat = 12
    static let regularGridSpacing: CGFloat = 16
    static let compactLibraryShelfMinWidth: CGFloat = 148
    static let compactLandscapeLibraryShelfMinWidth: CGFloat = 186
    static let regularLibraryShelfMinWidth: CGFloat = 220
    static let compactLibraryShelfHeight: CGFloat = 108
    static let regularLibraryShelfHeight: CGFloat = 112

    static let landscapeWidth: CGFloat = 220
    static let landscapeHeight: CGFloat = 124
    static let landscapePlayBadgeSize: CGFloat = 34

    private static func isPhoneLandscape(verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
    }

    private static func isPhonePortrait(verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .regular
    }

    static func libraryPosterWidth(horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        horizontalSizeClass == .regular ? posterWidth : compactPosterWidth
    }

    static func libraryGridSpacing(horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        horizontalSizeClass == .regular ? regularGridSpacing : compactGridSpacing
    }

    static func libraryGridPadding(horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        libraryGridSpacing(horizontalSizeClass: horizontalSizeClass)
    }

    static func libraryPosterColumns(horizontalSizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        [
            GridItem(
                .adaptive(minimum: libraryPosterWidth(horizontalSizeClass: horizontalSizeClass)),
                spacing: libraryGridSpacing(horizontalSizeClass: horizontalSizeClass),
                alignment: .top
            )
        ]
    }

    static func libraryThumbWidth(horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        horizontalSizeClass == .regular ? 210 : 160
    }

    static func libraryThumbColumns(horizontalSizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        [
            GridItem(
                .adaptive(minimum: libraryThumbWidth(horizontalSizeClass: horizontalSizeClass)),
                spacing: libraryGridSpacing(horizontalSizeClass: horizontalSizeClass),
                alignment: .top
            )
        ]
    }

    static func libraryShelfGridSpacing(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        if isPhoneLandscape(verticalSizeClass: verticalSizeClass) {
            return regularGridSpacing
        }
        return libraryGridSpacing(horizontalSizeClass: horizontalSizeClass)
    }

    static func libraryShelfPadding(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        if isPhoneLandscape(verticalSizeClass: verticalSizeClass) {
            return regularGridSpacing
        }
        return libraryGridPadding(horizontalSizeClass: horizontalSizeClass)
    }

    static func libraryShelfCardHeight(horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        horizontalSizeClass == .regular ? regularLibraryShelfHeight : compactLibraryShelfHeight
    }

    static func libraryShelfColumns(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        availableWidth: CGFloat? = nil,
        horizontalPadding: CGFloat? = nil
    ) -> [GridItem] {
        let spacing = libraryShelfGridSpacing(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        let padding = horizontalPadding ?? libraryShelfPadding(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        if let availableWidth, availableWidth > 0 {
            let contentWidth = max(availableWidth - (padding * 2), 0)
            let columnCount = libraryShelfColumnCount(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                availableWidth: contentWidth,
                spacing: spacing
            )
            return Array(
                repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: spacing, alignment: .top),
                count: columnCount
            )
        }
        let minimumWidth: CGFloat
        if horizontalSizeClass == .regular {
            minimumWidth = regularLibraryShelfMinWidth
        } else if isPhonePortrait(verticalSizeClass: verticalSizeClass) {
            return [
                GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: spacing, alignment: .top),
                GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: spacing, alignment: .top)
            ]
        } else if isPhoneLandscape(verticalSizeClass: verticalSizeClass) {
            minimumWidth = compactLandscapeLibraryShelfMinWidth
        } else {
            minimumWidth = compactLibraryShelfMinWidth
        }
        return [
            GridItem(
                .adaptive(minimum: minimumWidth, maximum: 320),
                spacing: spacing,
                alignment: .top
            )
        ]
    }

    private static func libraryShelfMinimumWidth(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        if horizontalSizeClass == .regular {
            return regularLibraryShelfMinWidth
        }
        if isPhoneLandscape(verticalSizeClass: verticalSizeClass) {
            return compactLandscapeLibraryShelfMinWidth
        }
        return compactLibraryShelfMinWidth
    }

    private static func libraryShelfColumnCount(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        availableWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        if horizontalSizeClass != .regular && isPhonePortrait(verticalSizeClass: verticalSizeClass) {
            return 2
        }

        let minimumWidth = libraryShelfMinimumWidth(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        let rawCount = Int((availableWidth + spacing) / (minimumWidth + spacing))
        return max(1, rawCount)
    }
}
