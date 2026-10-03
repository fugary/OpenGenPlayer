#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift

struct TVProfileRootView: View {
    private enum PendingStoredMediaAction: Identifiable {
        case deleteHistory(VideoFile)
        case removeFavorite(FavoriteItem)

        var id: String {
            switch self {
            case .deleteHistory(let file):
                return "delete-history-\(file.id)"
            case .removeFavorite(let item):
                return "remove-favorite-\(item.id)"
            }
        }
    }

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @AppStorage("enableVideoHistory") private var enableVideoHistory = true
    @AppStorage("enableAudioHistory") private var enableAudioHistory = true
    @Binding var selection: TVRootTab
    @State private var pendingStoredMediaAction: PendingStoredMediaAction?

    private var continueWatching: [VideoFile] {
        _ = enableVideoHistory
        _ = enableAudioHistory
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        _ = securityService.showPrivateHistory
        return Array(historyService.allHistory.filter {
            HistoryService.isHistoryEnabled(for: $0) && !tvShouldHidePrivateHistoryItem($0)
        }.prefix(12))
    }

    private var favoritePreview: [FavoriteItem] {
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return Array(favoriteService.favorites.filter { !tvShouldHidePrivateFavorite($0) }.prefix(12))
    }

    private var activeDownloadCount: Int { downloadCenter.activeJobs.count }
    private var completedDownloadCount: Int { downloadCenter.completedJobs.count }
    private var failedDownloadCount: Int { downloadCenter.failedJobs.count }
    private var totalDownloadCount: Int {
        activeDownloadCount + completedDownloadCount + failedDownloadCount
    }

    var body: some View {
        TVRootPageScrollView {
            // Play History
            if !continueWatching.isEmpty {
                TVShelfSection(
                    title: platformShellString("Play History"),
                    subtitle: platformShellString("Platform Shell TV Continue Watching Subtitle"),
                    systemImage: "clock.arrow.circlepath",
                    headerDestination: TVHistoryDetailView()
                ) {
                    ForEach(continueWatching) { file in
                        TVStoredMediaNavigationLink(file: file, intent: .revealParent) {
                            TVMediaLandscapeCard(file: file)
                        }
                        .contextMenu {
                            tvDeleteHistoryMenuButton(file: file) {
                                pendingStoredMediaAction = .deleteHistory(file)
                            }
                        }
                    }
                }
            } else {
                TVShelfSection(
                    title: platformShellString("Play History"),
                    subtitle: platformShellString("Platform Shell TV Continue Watching Subtitle"),
                    systemImage: "clock.arrow.circlepath",
                    headerDestination: TVHistoryDetailView()
                ) {
                    NavigationLink(destination: TVHistoryDetailView()) {
                        TVProfileEmptyPreviewCard(
                            title: platformShellString("Platform Shell TV Empty History Title"),
                            message: platformShellString("Platform Shell TV Empty History Body"),
                            systemImageName: "clock.arrow.circlepath"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }

            // Favorites
            if !favoritePreview.isEmpty {
                TVShelfSection(
                    title: platformShellString("Favorites"),
                    subtitle: platformShellString("Platform Shell TV Recent Favorites Subtitle"),
                    systemImage: "star",
                    headerDestination: TVFavoritesDetailView()
                ) {
                    ForEach(favoritePreview) { item in
                        TVStoredMediaNavigationLink(file: item.file, intent: .openItem) {
                            TVMediaCard(file: item.file)
                        }
                        .contextMenu {
                            tvRemoveFavoriteMenuButton(item: item) {
                                pendingStoredMediaAction = .removeFavorite(item)
                            }
                        }
                    }
                }
            } else {
                TVShelfSection(
                    title: platformShellString("Favorites"),
                    subtitle: platformShellString("Platform Shell TV Recent Favorites Subtitle"),
                    systemImage: "star",
                    headerDestination: TVFavoritesDetailView()
                ) {
                    NavigationLink(destination: TVFavoritesDetailView()) {
                        TVProfileEmptyPreviewCard(
                            title: platformShellString("Platform Shell TV Empty Favorites Title"),
                            message: platformShellString("Platform Shell TV Empty Favorites Body"),
                            systemImageName: "star"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }

            TVShelfSection(
                title: platformShellString("Downloads"),
                subtitle: platformShellString("Platform Shell TV Active Downloads Subtitle"),
                systemImage: "arrow.down.circle",
                headerDestination: TVDownloadsDetailView()
            ) {
                if totalDownloadCount > 0 {
                    NavigationLink(destination: TVDownloadsDetailView()) {
                        TVProfileDownloadEntryRow(
                            activeCount: activeDownloadCount,
                            completedCount: completedDownloadCount,
                            failedCount: failedDownloadCount
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                } else {
                    NavigationLink(destination: TVDownloadsDetailView()) {
                        TVProfileEmptyPreviewCard(
                            title: platformShellString("Platform Shell TV Empty Downloads Title"),
                            message: platformShellString("Platform Shell TV Empty Downloads Body"),
                            systemImageName: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }
        }
        .navigationTitle(Text(platformShellString("My")))
        .alert(item: $pendingStoredMediaAction) { action in
            switch action {
            case .deleteHistory(let file):
                return tvDeleteHistoryAlert(for: file) {
                    historyService.removeFromHistory(file)
                }
            case .removeFavorite(let item):
                return tvRemoveFavoriteAlert(for: item) {
                    favoriteService.remove(item)
                }
            }
        }
    }
}



enum TVProfilePreviewCardMetrics {
    static let width: CGFloat = 560
    static let height: CGFloat = 150
    static let iconSize: CGFloat = 66
    static let cornerRadius: CGFloat = 24
    static let horizontalPadding: CGFloat = 24
}



struct TVProfileDownloadEntryRow: View {
    let activeCount: Int
    let completedCount: Int
    let failedCount: Int

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var totalCount: Int {
        activeCount + completedCount + failedCount
    }

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(TVShellStyle.accentSoft.opacity(showsFocus ? 0.24 : 0.14))

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(TVShellStyle.accentSoft)
            }
            .frame(width: TVProfilePreviewCardMetrics.iconSize, height: TVProfilePreviewCardMetrics.iconSize)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(platformShellString("Downloads"))
                        .font(.system(size: 25, weight: .heavy))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("\(totalCount)")
                        .font(.system(size: 18, weight: .heavy, design: .monospaced))
                        .foregroundColor(TVShellStyle.secondary)
                        .frame(minWidth: 30)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(showsFocus ? 0.12 : 0.08))
                        )
                }

                HStack(spacing: 12) {
                    TVProfileDownloadStatusMetric(
                        title: platformShellString("Active"),
                        count: activeCount,
                        tint: TVShellStyle.accentSoft,
                        showsFocus: showsFocus
                    )
                    TVProfileDownloadStatusMetric(
                        title: platformShellString("Completed"),
                        count: completedCount,
                        tint: Color(red: 0.48, green: 0.88, blue: 0.62),
                        showsFocus: showsFocus
                    )
                    TVProfileDownloadStatusMetric(
                        title: platformShellString("Failed"),
                        count: failedCount,
                        tint: Color(red: 1.0, green: 0.48, blue: 0.40),
                        showsFocus: showsFocus
                    )
                }
            }

            Spacer(minLength: 24)

            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(TVShellStyle.secondary)
        }
        .padding(.horizontal, TVProfilePreviewCardMetrics.horizontalPadding)
        .frame(
            width: TVProfilePreviewCardMetrics.width,
            height: TVProfilePreviewCardMetrics.height,
            alignment: .leading
        )
        .contentShape(RoundedRectangle(cornerRadius: TVProfilePreviewCardMetrics.cornerRadius, style: .continuous))
        .modifier(
            TVSurfaceModifier(
                cornerRadius: TVProfilePreviewCardMetrics.cornerRadius,
                baseFill: TVShellStyle.surface.opacity(0.78),
                focusedFill: TVShellStyle.elevatedSurface,
                baseStroke: TVShellStyle.glassStroke,
                focusedStroke: Color.white.opacity(0.24),
                focusedScale: 1.018,
                shadowOpacity: 0.26
            )
        )
        .modifier(TVFocusedCardLayerModifier())
    }
}



struct TVProfileDownloadStatusMetric: View {
    let title: String
    let count: Int
    let tint: Color
    let showsFocus: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint.opacity(showsFocus ? 1.0 : 0.78))
                .frame(width: 8, height: 8)

            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(TVShellStyle.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text("\(count)")
                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                .foregroundColor(TVShellStyle.primary.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}



struct TVHistoryDetailView: View {
    private enum ClearTarget: Identifiable {
        case all
        case group(TVHistoryGroup)
        case item(VideoFile)

        var id: String {
            switch self {
            case .all:
                return "all"
            case .group(let group):
                return "group-\(group.id)"
            case .item(let file):
                return "item-\(file.id)"
            }
        }
    }

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @AppStorage("enableVideoHistory") private var enableVideoHistory = true
    @AppStorage("enableAudioHistory") private var enableAudioHistory = true
    @State private var clearTarget: ClearTarget?
    @State private var focusedHeaderAction: TVHeaderActionFocus?

    private var groups: [TVHistoryGroup] {
        _ = enableVideoHistory
        _ = enableAudioHistory
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        _ = securityService.showPrivateHistory
        return TVShellGrouping.historyGroups(
            history: historyService.allHistory.filter {
                HistoryService.isHistoryEnabled(for: $0) && !tvShouldHidePrivateHistoryItem($0)
            },
            servers: networkService.servers
        )
    }

    var body: some View {
        TVPageScrollView(
            title: platformShellString("Play History"),
            subtitle: nil,
            handlesExitCommand: true,
            showsTitle: false
        ) {
            TVDetailActionHeader(
                title: platformShellString("Play History"),
                systemImage: "clock.arrow.circlepath",
                headerAccessory: groups.isEmpty ? nil : AnyView(historyHeaderActions)
            )

            if groups.isEmpty {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Empty History Title"),
                    message: platformShellString("Platform Shell TV Empty History Body"),
                    systemImageName: "clock.arrow.circlepath"
                )
            } else {
                ForEach(groups) { group in
                    TVShelfSection(
                        title: group.title,
                        subtitle: tvGroupSubtitle(for: group.server),
                        headerServer: group.server,
                        headerAccessory: clearHistoryGroupAccessory(group)
                    ) {
                        ForEach(group.items) { file in
                            TVStoredMediaNavigationLink(file: file, intent: .revealParent) {
                                TVMediaCard(file: file)
                            }
                            .contextMenu {
                                tvDeleteHistoryMenuButton(file: file) {
                                    clearTarget = .item(file)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(platformShellString("Play History")))
        .alert(item: $clearTarget) { target in
            switch target {
            case .all:
                return Alert(
                    title: Text(platformShellString("Clear History")),
                    message: Text(platformShellString("Are you sure you want to clear all play history?")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        let shouldExcludePrivate = securityService.isPrivacySpaceEnabled &&
                            (!securityService.isPrivacySpaceUnlocked || !securityService.showPrivateHistory)
                        historyService.clearHistory(excludingPrivate: shouldExcludePrivate)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .group(let group):
                return Alert(
                    title: Text(platformShellString("Clear Group")),
                    message: Text(group.title),
                    primaryButton: .destructive(Text(platformShellString("Clear Group"))) {
                        historyService.clearHistory(for: group.items)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .item(let file):
                return tvDeleteHistoryAlert(for: file) {
                    historyService.removeFromHistory(file)
                }
            }
        }
    }

    private var historyHeaderActions: some View {
        let clearActionID = "history-clear-all"
        let clearActionTitle = platformShellString("Clear History")
        let eyeActionID = "history-toggle-privacy-eye"
        let isEyeOpen = securityService.showPrivateHistory
        let eyeActionTitle = platformShellString(isEyeOpen ? "Hide Private History" : "Show Private History")

        return HStack(spacing: 14) {
            if securityService.isPrivacySpaceEnabled && securityService.excludePrivacyFromHistory && securityService.isPrivacySpaceUnlocked {
                Button(action: togglePrivacySpaceEye) {
                    TVHeaderIconActionButton(
                        title: eyeActionTitle,
                        systemImageName: isEyeOpen ? "eye" : "eye.slash",
                        isDestructive: false,
                        onFocusChange: { _, isFocused in
                            handleHeaderActionFocus(
                                id: eyeActionID,
                                title: eyeActionTitle,
                                isFocused: isFocused,
                                isDestructive: false
                            )
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            Button(action: {
                clearTarget = .all
            }) {
                TVHeaderIconActionButton(
                    title: clearActionTitle,
                    systemImageName: "trash",
                    isDestructive: true,
                    onFocusChange: { _, isFocused in
                        handleHeaderActionFocus(
                            id: clearActionID,
                            title: clearActionTitle,
                            isFocused: isFocused,
                            isDestructive: true
                        )
                    }
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

            TVHeaderActionDescriptionText(
                text: actionDescription(for: focusedHeaderAction?.id ?? clearActionID),
                isDestructive: focusedHeaderAction?.isDestructive ?? false
            )
        }
    }

    private func togglePrivacySpaceEye() {
        withAnimation {
            securityService.showPrivateHistory.toggle()
        }
    }

    private func clearHistoryGroupAccessory(_ group: TVHistoryGroup) -> AnyView {
        let actionID = "history-clear-group-\(group.id)"
        let actionTitle = platformShellString("Clear Group")
        return AnyView(
            HStack(spacing: 14) {
                Button(action: {
                    clearTarget = .group(group)
                }) {
                    TVHeaderIconActionButton(
                        title: actionTitle,
                        systemImageName: "trash",
                        isDestructive: true,
                        onFocusChange: { _, isFocused in
                            handleHeaderActionFocus(
                                id: actionID,
                                title: actionTitle,
                                isFocused: isFocused,
                                isDestructive: true
                            )
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()

                TVHeaderActionDescriptionText(
                    text: actionDescription(for: actionID),
                    width: 280,
                    isDestructive: focusedHeaderAction?.isDestructive ?? false
                )
            }
        )
    }

    private func handleHeaderActionFocus(id: String, title: String, isFocused: Bool, isDestructive: Bool = false) {
        if isFocused {
            focusedHeaderAction = TVHeaderActionFocus(id: id, title: title, isDestructive: isDestructive)
        } else if focusedHeaderAction?.id == id {
            focusedHeaderAction = nil
        }
    }

    private func actionDescription(for id: String) -> String? {
        focusedHeaderAction?.id == id ? focusedHeaderAction?.title : nil
    }
}



struct TVFavoritesDetailView: View {
    private enum ClearTarget: Identifiable {
        case all
        case group(TVFavoriteGroup)
        case item(FavoriteItem)

        var id: String {
            switch self {
            case .all:
                return "all"
            case .group(let group):
                return "group-\(group.id)"
            case .item(let item):
                return "item-\(item.id)"
            }
        }
    }

    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @State private var clearTarget: ClearTarget?
    @State private var focusedHeaderAction: TVHeaderActionFocus?

    private var groups: [TVFavoriteGroup] {
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return TVShellGrouping.favoriteGroups(
            favorites: favoriteService.favorites.filter { !tvShouldHidePrivateFavorite($0) },
            servers: networkService.servers
        )
    }

    var body: some View {
        TVPageScrollView(
            title: platformShellString("Favorites"),
            subtitle: nil,
            handlesExitCommand: true,
            showsTitle: false
        ) {
            TVDetailActionHeader(
                title: platformShellString("Favorites"),
                systemImage: "star",
                headerAccessory: groups.isEmpty ? nil : AnyView(favoritesHeaderActions)
            )

            if groups.isEmpty {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Empty Favorites Title"),
                    message: platformShellString("Platform Shell TV Empty Favorites Body"),
                    systemImageName: "star"
                )
            } else {
                ForEach(groups) { group in
                    TVShelfSection(
                        title: group.title,
                        subtitle: tvGroupSubtitle(for: group.server),
                        headerServer: group.server,
                        headerAccessory: clearFavoritesGroupAccessory(group)
                    ) {
                        ForEach(group.items) { item in
                            TVStoredMediaNavigationLink(file: item.file, intent: .openItem) {
                                TVMediaCard(file: item.file)
                            }
                            .contextMenu {
                                tvRemoveFavoriteMenuButton(item: item) {
                                    clearTarget = .item(item)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(platformShellString("Favorites")))
        .alert(item: $clearTarget) { target in
            switch target {
            case .all:
                return Alert(
                    title: Text(platformShellString("Clear Favorites")),
                    message: Text(platformShellString("Are you sure you want to remove all favorites?")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        favoriteService.clearAll()
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .group(let group):
                return Alert(
                    title: Text(platformShellString("Clear Group")),
                    message: Text(group.title),
                    primaryButton: .destructive(Text(platformShellString("Clear Group"))) {
                        group.items.forEach { favoriteService.remove($0) }
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .item(let item):
                return tvRemoveFavoriteAlert(for: item) {
                    favoriteService.remove(item)
                }
            }
        }
    }

    private var favoritesHeaderActions: some View {
        let actionID = "favorites-clear-all"
        let actionTitle = platformShellString("Clear Favorites")
        return HStack(spacing: 14) {
            Button(action: {
                clearTarget = .all
            }) {
                TVHeaderIconActionButton(
                    title: actionTitle,
                    systemImageName: "trash",
                    isDestructive: true,
                    onFocusChange: { _, isFocused in
                        handleHeaderActionFocus(
                            id: actionID,
                            title: actionTitle,
                            isFocused: isFocused,
                            isDestructive: true
                        )
                    }
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

            TVHeaderActionDescriptionText(
                text: actionDescription(for: actionID),
                isDestructive: focusedHeaderAction?.isDestructive ?? false
            )
        }
    }

    private func clearFavoritesGroupAccessory(_ group: TVFavoriteGroup) -> AnyView {
        let actionID = "favorites-clear-group-\(group.id)"
        let actionTitle = platformShellString("Clear Group")
        return AnyView(
            HStack(spacing: 14) {
                Button(action: {
                    clearTarget = .group(group)
                }) {
                    TVHeaderIconActionButton(
                        title: actionTitle,
                        systemImageName: "trash",
                        isDestructive: true,
                        onFocusChange: { _, isFocused in
                            handleHeaderActionFocus(
                                id: actionID,
                                title: actionTitle,
                                isFocused: isFocused,
                                isDestructive: true
                            )
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()

                TVHeaderActionDescriptionText(
                    text: actionDescription(for: actionID),
                    width: 280,
                    isDestructive: focusedHeaderAction?.isDestructive ?? false
                )
            }
        )
    }

    private func handleHeaderActionFocus(id: String, title: String, isFocused: Bool, isDestructive: Bool = false) {
        if isFocused {
            focusedHeaderAction = TVHeaderActionFocus(id: id, title: title, isDestructive: isDestructive)
        } else if focusedHeaderAction?.id == id {
            focusedHeaderAction = nil
        }
    }

    private func actionDescription(for id: String) -> String? {
        focusedHeaderAction?.id == id ? focusedHeaderAction?.title : nil
    }
}



struct TVDestructiveMenuLabel: View {
    let title: String
    let systemImageName: String

    var body: some View {
        Label {
            Text(title)
                .foregroundColor(.red)
        } icon: {
            Image(systemName: systemImageName)
                .foregroundColor(.red)
        }
    }
}



struct TVDownloadsDetailView: View {
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var selectedFilter: TVDownloadListFilter
    @State private var hasAppliedInitialFilter = false
    @State private var pendingAction: TVDownloadPendingDestructiveAction?
    @State private var focusedSectionAction: TVHeaderActionFocus?
    @Environment(\.tvSettingsInlinePresentation) private var isInlineSettingsPresentation

    init() {
        _selectedFilter = State(initialValue: Self.preferredInitialFilter())
    }

    private var jobs: [DownloadJobGroup] {
        downloadCenter.jobs
    }

    private var filterAvailabilityKey: String {
        [
            downloadCenter.activeJobs.count,
            downloadCenter.completedJobs.count,
            downloadCenter.failedJobs.count
        ]
        .map(String.init)
        .joined(separator: "-")
    }

    private func jobs(for filter: TVDownloadListFilter) -> [DownloadJobGroup] {
        switch filter {
        case .active:
            return downloadCenter.activeJobs
        case .completed:
            return downloadCenter.completedJobs
        case .failed:
            return downloadCenter.failedJobs
        }
    }

    private func groupedSections(for filter: TVDownloadListFilter) -> [TVDownloadDateGroup] {
        let grouped = Dictionary(grouping: jobs(for: filter)) { job in
            Calendar.current.startOfDay(for: job.createdAt)
        }

        return grouped.keys.sorted(by: >).map { day in
            TVDownloadDateGroup(
                date: day,
                jobs: grouped[day]?.sorted(by: { $0.createdAt > $1.createdAt }) ?? []
            )
        }
    }

    var body: some View {
        downloadsPage {
            downloadsContent
        }
        .navigationTitle(Text(platformShellString("Downloads")))
        .onAppear(perform: applyInitialFilterIfNeeded)
        .onChange(of: filterAvailabilityKey) { _ in
            applyInitialFilterIfNeeded()
        }
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(title(for: action)),
                message: Text(action.message),
                primaryButton: .destructive(Text(confirmTitle(for: action))) {
                    confirm(action)
                },
                secondaryButton: .cancel(Text(platformShellString("Cancel")))
            )
        }
    }

    @ViewBuilder
    private var downloadsContent: some View {
        if jobs.isEmpty {
            TVEmptyStateCard(
                title: platformShellString("Platform Shell TV Empty Downloads Title"),
                message: platformShellString("Platform Shell TV Empty Downloads Body"),
                systemImageName: "arrow.down.circle"
            )
        } else {
            TVDownloadFilterBar(
                selectedFilter: $selectedFilter,
                activeCount: downloadCenter.activeJobs.count,
                completedCount: downloadCenter.completedJobs.count,
                failedCount: downloadCenter.failedJobs.count
            )

            if let globalActions = downloadGlobalActions(for: selectedFilter) {
                globalActions
            }

            downloadTabContent(for: selectedFilter)
        }
    }

    @ViewBuilder
    private func downloadsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let pageContent = content()

        if isInlineSettingsPresentation {
            TVSettingsInlinePage(
                title: platformShellString("Downloads"),
                systemImageName: "arrow.down.circle.fill"
            ) {
                pageContent
            }
        } else {
            TVPageScrollView(
                title: platformShellString("Downloads"),
                subtitle: nil,
                handlesExitCommand: true
            ) {
                pageContent
            }
        }
    }

    @ViewBuilder
    private func downloadTabContent(for filter: TVDownloadListFilter) -> some View {
        let currentJobs = jobs(for: filter)

        if currentJobs.isEmpty {
            TVEmptyStateCard(
                title: platformShellString("Platform Shell TV Empty Downloads Title"),
                message: platformShellString("Platform Shell TV Empty Downloads Body"),
                systemImageName: filter.systemImageName
            )
        } else {
            LazyVStack(spacing: 26) {
                ForEach(groupedSections(for: filter)) { section in
                    let sectionTitle = tvDownloadDateString(section.date)

                    TVDownloadDateSection(
                        title: sectionTitle,
                        jobs: section.jobs,
                        headerAccessory: downloadSectionActions(for: section, filter: filter),
                        rowContextMenu: { job in
                            jobContextMenu(for: job)
                        }
                    )
                }
            }
        }
    }

    private static func preferredInitialFilter() -> TVDownloadListFilter {
        let downloadCenter = DownloadCenterService.shared
        if !downloadCenter.activeJobs.isEmpty {
            return .active
        }
        if !downloadCenter.completedJobs.isEmpty {
            return .completed
        }
        if !downloadCenter.failedJobs.isEmpty {
            return .failed
        }
        return .active
    }

    private func applyInitialFilterIfNeeded() {
        guard !hasAppliedInitialFilter else { return }
        guard !jobs.isEmpty else { return }
        hasAppliedInitialFilter = true
        selectedFilter = Self.preferredInitialFilter()
    }

    @ViewBuilder
    private func jobContextMenu(for job: DownloadJobGroup) -> some View {
        TVDownloadJobContextMenuContent(
            snapshot: TVDownloadJobMenuSnapshot(job: job),
            pauseOrResume: {
                if job.primaryStatus == .paused {
                    downloadCenter.resume(jobId: job.id)
                } else {
                    downloadCenter.pause(jobId: job.id)
                }
            },
            retry: {
                downloadCenter.retry(jobId: job.id)
            },
            cancel: {
                queueJobAction(job, kind: .cancelDownloads)
            },
            deleteFiles: {
                queueJobAction(job, kind: .deleteFiles)
            },
            deleteRecords: {
                queueJobAction(job, kind: .deleteRecords)
            }
        )
        .equatable()
    }

    private var activePauseStatuses: [DownloadTaskStatus] {
        [.queued, .downloading]
    }

    private var activeResumeStatuses: [DownloadTaskStatus] {
        [.paused]
    }

    private var activeCancelableStatuses: [DownloadTaskStatus] {
        [.queued, .downloading, .paused]
    }

    private func sectionRecordCount(for section: TVDownloadDateGroup, statuses: [DownloadTaskStatus]) -> Int {
        recordCount(in: section.jobs, statuses: statuses)
    }

    private func downloadGlobalActions(for filter: TVDownloadListFilter) -> AnyView? {
        let prefix = "download-global-\(filter.titleKey)"

        switch filter {
        case .active:
            let cancelCount = recordCount(in: downloadCenter.activeJobs, statuses: activeCancelableStatuses)
            guard cancelCount > 0 else { return nil }

            return AnyView(
                HStack(spacing: 14) {
                    TVDownloadSelectedFilterSummary(
                        filter: filter,
                        count: jobs(for: filter).count
                    )

                    downloadSectionActionButton(
                        id: "\(prefix)-cancel",
                        title: platformShellString("Cancel Active Downloads"),
                        systemImageName: "xmark.circle",
                        isDestructive: true
                    ) {
                        queueGlobalAction(
                            kind: .cancelDownloads,
                            statuses: activeCancelableStatuses,
                            recordCount: cancelCount
                        )
                    }

                    TVHeaderActionDescriptionText(
                        text: sectionActionDescription(for: prefix),
                        width: 340,
                        isDestructive: focusedSectionAction?.isDestructive ?? false
                    )
                }
                .frame(minWidth: 0, alignment: .leading)
                .tvFocusSectionIfAvailable()
            )
        case .completed, .failed:
            guard let statuses = filter.cleanupStatuses else { return nil }
            let recordCount = recordCount(in: jobs(for: filter), statuses: statuses)
            guard recordCount > 0 else { return nil }

            return AnyView(
                HStack(spacing: 14) {
                    TVDownloadSelectedFilterSummary(
                        filter: filter,
                        count: jobs(for: filter).count
                    )

                    downloadSectionActionButton(
                        id: "\(prefix)-delete-files",
                        title: platformShellString("Delete Files"),
                        systemImageName: "trash",
                        isDestructive: true
                    ) {
                        queueGlobalAction(
                            kind: .deleteFiles,
                            statuses: statuses,
                            recordCount: recordCount
                        )
                    }

                    downloadSectionActionButton(
                        id: "\(prefix)-delete-records",
                        title: platformShellString("Delete Records"),
                        systemImageName: "minus.circle",
                        isDestructive: true
                    ) {
                        queueGlobalAction(
                            kind: .deleteRecords,
                            statuses: statuses,
                            recordCount: recordCount
                        )
                    }

                    TVHeaderActionDescriptionText(
                        text: sectionActionDescription(for: prefix),
                        width: 340,
                        isDestructive: focusedSectionAction?.isDestructive ?? false
                    )
                }
                .frame(minWidth: 0, alignment: .leading)
                .tvFocusSectionIfAvailable()
            )
        }
    }

    private func downloadSectionActions(for section: TVDownloadDateGroup, filter: TVDownloadListFilter) -> AnyView? {
        let prefix = "download-section-\(section.date.timeIntervalSince1970)"

        switch filter {
        case .active:
            let pauseCount = sectionRecordCount(for: section, statuses: activePauseStatuses)
            let resumeCount = sectionRecordCount(for: section, statuses: activeResumeStatuses)
            let cancelCount = sectionRecordCount(for: section, statuses: activeCancelableStatuses)
            guard pauseCount > 0 || resumeCount > 0 || cancelCount > 0 else { return nil }

            return AnyView(
                HStack(spacing: 14) {
                    if pauseCount > 0 {
                        downloadSectionActionButton(
                            id: "\(prefix)-pause",
                            title: platformShellString("Pause All"),
                            systemImageName: "pause.fill",
                            isDestructive: false
                        ) {
                            downloadCenter.pauseRecords(createdOn: section.date, statuses: activePauseStatuses)
                        }
                    }

                    if resumeCount > 0 {
                        downloadSectionActionButton(
                            id: "\(prefix)-resume",
                            title: platformShellString("Resume All"),
                            systemImageName: "play.fill",
                            isDestructive: false
                        ) {
                            downloadCenter.resumeRecords(createdOn: section.date, statuses: activeResumeStatuses)
                        }
                    }

                    if cancelCount > 0 {
                        downloadSectionActionButton(
                            id: "\(prefix)-cancel",
                            title: platformShellString("Cancel Active Downloads"),
                            systemImageName: "xmark.circle",
                            isDestructive: true
                        ) {
                            queueSectionAction(
                                section,
                                kind: .cancelDownloads,
                                statuses: activeCancelableStatuses,
                                recordCount: cancelCount
                            )
                        }
                    }

                    TVHeaderActionDescriptionText(text: sectionActionDescription(for: prefix), width: 340, isDestructive: focusedSectionAction?.isDestructive ?? false)
                }
            )
        case .completed, .failed:
            guard let statuses = filter.cleanupStatuses else { return nil }
            let recordCount = sectionRecordCount(for: section, statuses: statuses)
            guard recordCount > 0 else { return nil }

            return AnyView(
                HStack(spacing: 14) {
                    downloadSectionActionButton(
                        id: "\(prefix)-delete-files",
                        title: platformShellString("Delete Files"),
                        systemImageName: "trash",
                        isDestructive: true
                    ) {
                        queueSectionAction(
                            section,
                            kind: .deleteFiles,
                            statuses: statuses,
                            recordCount: recordCount
                        )
                    }

                    downloadSectionActionButton(
                        id: "\(prefix)-delete-records",
                        title: platformShellString("Delete Records"),
                        systemImageName: "minus.circle",
                        isDestructive: true
                    ) {
                        queueSectionAction(
                            section,
                            kind: .deleteRecords,
                            statuses: statuses,
                            recordCount: recordCount
                        )
                    }

                    TVHeaderActionDescriptionText(text: sectionActionDescription(for: prefix), width: 340, isDestructive: focusedSectionAction?.isDestructive ?? false)
                }
            )
        }
    }

    private func downloadSectionActionButton(
        id: String,
        title: String,
        systemImageName: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TVHeaderIconActionButton(
                title: title,
                systemImageName: systemImageName,
                isDestructive: isDestructive,
                onFocusChange: { _, isFocused in
                    handleSectionActionFocus(id: id, title: title, isFocused: isFocused, isDestructive: isDestructive)
                }
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }

    private func handleSectionActionFocus(id: String, title: String, isFocused: Bool, isDestructive: Bool = false) {
        if isFocused {
            focusedSectionAction = TVHeaderActionFocus(id: id, title: title, isDestructive: isDestructive)
        } else if focusedSectionAction?.id == id {
            focusedSectionAction = nil
        }
    }

    private func sectionActionDescription(for prefix: String) -> String? {
        guard let focusedSectionAction,
              focusedSectionAction.id.hasPrefix(prefix)
        else {
            return nil
        }
        return focusedSectionAction.title
    }

    private func queueGlobalAction(
        kind: TVDownloadDestructiveKind,
        statuses: [DownloadTaskStatus],
        recordCount: Int
    ) {
        let count = max(recordCount, 1)
        pendingAction = TVDownloadPendingDestructiveAction(
            kind: kind,
            recordCount: count,
            message: message(
                for: kind,
                recordCount: count,
                scopeTitle: platformShellString("Downloads")
            ),
            sectionDate: nil,
            statuses: statuses,
            jobId: nil
        )
    }

    private func queueSectionAction(
        _ section: TVDownloadDateGroup,
        kind: TVDownloadDestructiveKind,
        statuses: [DownloadTaskStatus],
        recordCount: Int
    ) {
        let count = max(recordCount, 1)
        pendingAction = TVDownloadPendingDestructiveAction(
            kind: kind,
            recordCount: count,
            message: message(for: kind, recordCount: count, scopeTitle: tvDownloadDateString(section.date)),
            sectionDate: section.date,
            statuses: statuses,
            jobId: nil
        )
    }

    private func queueJobAction(_ job: DownloadJobGroup, kind: TVDownloadDestructiveKind) {
        let recordCount: Int
        switch kind {
        case .cancelDownloads:
            recordCount = max(job.tasks.filter(\.isActive).count, 1)
        case .deleteFiles, .deleteRecords:
            recordCount = max(job.itemCount, 1)
        }

        pendingAction = TVDownloadPendingDestructiveAction(
            kind: kind,
            recordCount: recordCount,
            message: message(for: kind, recordCount: recordCount, scopeTitle: job.title),
            sectionDate: nil,
            statuses: nil,
            jobId: job.id
        )
    }

    private func confirm(_ action: TVDownloadPendingDestructiveAction) {
        defer { pendingAction = nil }

        switch action.kind {
        case .cancelDownloads:
            if let taskId = action.taskId {
                downloadCenter.cancel(taskId)
            } else if let jobId = action.jobId {
                downloadCenter.cancel(jobId: jobId)
            } else if let date = action.sectionDate, let statuses = action.statuses {
                downloadCenter.cancelRecords(createdOn: date, statuses: statuses)
            } else {
                for job in downloadCenter.activeJobs {
                    downloadCenter.cancel(jobId: job.id)
                }
            }
        case .deleteFiles:
            if let taskId = action.taskId {
                downloadCenter.removeRecord(taskId, deleteLocalFile: true)
            } else if let jobId = action.jobId {
                downloadCenter.removeJob(jobId, deleteLocalFile: true)
            } else if let date = action.sectionDate, let statuses = action.statuses {
                downloadCenter.removeRecords(createdOn: date, statuses: statuses, deleteLocalFiles: true)
            } else if let statuses = action.statuses {
                downloadCenter.removeRecords(statuses: statuses, deleteLocalFiles: true)
            }
        case .deleteRecords:
            if let taskId = action.taskId {
                downloadCenter.removeRecord(taskId, deleteLocalFile: false)
            } else if let jobId = action.jobId {
                downloadCenter.removeJob(jobId, deleteLocalFile: false)
            } else if let date = action.sectionDate, let statuses = action.statuses {
                downloadCenter.removeRecords(createdOn: date, statuses: statuses, deleteLocalFiles: false)
            } else if let statuses = action.statuses {
                downloadCenter.removeRecords(statuses: statuses, deleteLocalFiles: false)
            }
        }
    }

    private func recordCount(in jobs: [DownloadJobGroup], statuses: [DownloadTaskStatus]) -> Int {
        jobs.reduce(0) { partial, job in
            partial + job.tasks.filter { statuses.contains($0.status) }.count
        }
    }

    private func title(for action: TVDownloadPendingDestructiveAction) -> String {
        switch action.kind {
        case .cancelDownloads:
            return platformShellString(action.recordCount <= 1 ? "Cancel Download" : "Cancel Downloads")
        case .deleteFiles:
            return platformShellString(action.recordCount <= 1 ? "Delete File" : "Delete Files")
        case .deleteRecords:
            return platformShellString(action.recordCount <= 1 ? "Delete Record" : "Delete Records")
        }
    }

    private func confirmTitle(for action: TVDownloadPendingDestructiveAction) -> String {
        switch action.kind {
        case .cancelDownloads:
            return platformShellString(action.recordCount <= 1 ? "Cancel Download" : "Cancel Downloads")
        case .deleteFiles, .deleteRecords:
            return platformShellString("Delete")
        }
    }

    private func message(for kind: TVDownloadDestructiveKind, recordCount: Int, scopeTitle: String) -> String {
        switch kind {
        case .cancelDownloads:
            return String(format: platformShellString("Platform Shell TV Cancel Downloads Confirm Format"), scopeTitle)
        case .deleteFiles:
            return String(format: platformShellString("Platform Shell TV Delete Download Files Confirm Format"), scopeTitle)
        case .deleteRecords:
            return String(format: platformShellString("Platform Shell TV Delete Download Records Confirm Format"), scopeTitle)
        }
    }
}



struct TVHistoryGroup: Identifiable {
    let id: String
    let title: String
    let items: [VideoFile]
    let server: ServerConfig?
}
#endif
