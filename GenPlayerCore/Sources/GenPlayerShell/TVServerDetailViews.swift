#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVServerHistoryDetailView: View {
    private enum ClearTarget: Identifiable {
        case server
        case group(title: String, items: [VideoFile])
        case item(VideoFile)

        var id: String {
            switch self {
            case .server:
                return "server"
            case .group(let title, _):
                return "group-\(title)"
            case .item(let file):
                return "item-\(file.id)"
            }
        }
    }

    let server: ServerConfig

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @AppStorage("enableVideoHistory") private var enableVideoHistory = true
    @AppStorage("enableAudioHistory") private var enableAudioHistory = true
    @State private var clearTarget: ClearTarget?
    @State private var focusedHeaderAction: TVHeaderActionFocus?

    private var historyItems: [VideoFile] {
        _ = enableVideoHistory
        _ = enableAudioHistory
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return historyService.allHistory.filter { file in
            guard HistoryService.isHistoryEnabled(for: file) else { return false }
            guard !tvShouldHidePrivateFile(file) else { return false }
            return file.tvResolvedServer(from: networkService.servers)?.id == server.id
        }
    }

    private var groups: [(type: VideoFile.FileType, items: [VideoFile])] {
        tvGroupedVideoFiles(historyItems)
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
                headerAccessory: groups.isEmpty ? nil : AnyView(serverHistoryHeaderActions)
            )

            if groups.isEmpty {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Empty History Title"),
                    message: platformShellString("Platform Shell TV Empty History Body"),
                    systemImageName: "clock.arrow.circlepath"
                )
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let title = tvMediaTypeTitle(for: group.type)
                    TVShelfSection(
                        title: title,
                        subtitle: nil,
                        headerAccessory: clearServerHistoryGroupAccessory(title: title, items: group.items)
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
            case .server:
                return Alert(
                    title: Text(platformShellString("Clear History")),
                    message: Text(server.name),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        historyService.clearHistory(for: historyItems)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .group(let title, let items):
                return Alert(
                    title: Text(platformShellString("Clear Group")),
                    message: Text(title),
                    primaryButton: .destructive(Text(platformShellString("Clear Group"))) {
                        historyService.clearHistory(for: items)
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

    private var serverHistoryHeaderActions: some View {
        let actionID = "server-history-clear-all"
        let actionTitle = platformShellString("Clear History")
        return HStack(spacing: 14) {
            Button(action: {
                clearTarget = .server
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

            TVHeaderActionDescriptionText(text: actionDescription(for: actionID), isDestructive: focusedHeaderAction?.isDestructive ?? false)
        }
    }

    private func clearServerHistoryGroupAccessory(title: String, items: [VideoFile]) -> AnyView {
        let actionID = "server-history-clear-group-\(title)"
        let actionTitle = platformShellString("Clear Group")
        return AnyView(
            HStack(spacing: 14) {
                Button(action: {
                    clearTarget = .group(title: title, items: items)
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

                TVHeaderActionDescriptionText(text: actionDescription(for: actionID), width: 280, isDestructive: focusedHeaderAction?.isDestructive ?? false)
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



struct TVServerFavoritesDetailView: View {
    private enum ClearTarget: Identifiable {
        case server
        case group(title: String, items: [FavoriteItem])
        case item(FavoriteItem)

        var id: String {
            switch self {
            case .server:
                return "server"
            case .group(let title, _):
                return "group-\(title)"
            case .item(let item):
                return "item-\(item.id)"
            }
        }
    }

    let server: ServerConfig

    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @State private var clearTarget: ClearTarget?
    @State private var focusedHeaderAction: TVHeaderActionFocus?

    private var favoriteItems: [FavoriteItem] {
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return favoriteService.favorites.filter { item in
            guard !tvShouldHidePrivateFavorite(item) else { return false }
            return item.file.tvResolvedServer(from: networkService.servers)?.id == server.id
        }
    }

    private var groups: [(type: VideoFile.FileType, items: [FavoriteItem])] {
        tvGroupedFavoriteItems(favoriteItems)
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
                headerAccessory: groups.isEmpty ? nil : AnyView(serverFavoritesHeaderActions)
            )

            if groups.isEmpty {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Empty Favorites Title"),
                    message: platformShellString("Platform Shell TV Empty Favorites Body"),
                    systemImageName: "star"
                )
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let title = tvMediaTypeTitle(for: group.type)
                    TVShelfSection(
                        title: title,
                        subtitle: nil,
                        headerAccessory: clearServerFavoritesGroupAccessory(title: title, items: group.items)
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
            case .server:
                return Alert(
                    title: Text(platformShellString("Clear Favorites")),
                    message: Text(server.name),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        favoriteItems.forEach { favoriteService.remove($0) }
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .group(let title, let items):
                return Alert(
                    title: Text(platformShellString("Clear Group")),
                    message: Text(title),
                    primaryButton: .destructive(Text(platformShellString("Clear Group"))) {
                        items.forEach { favoriteService.remove($0) }
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

    private var serverFavoritesHeaderActions: some View {
        let actionID = "server-favorites-clear-all"
        let actionTitle = platformShellString("Clear Favorites")
        return HStack(spacing: 14) {
            Button(action: {
                clearTarget = .server
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

            TVHeaderActionDescriptionText(text: actionDescription(for: actionID), isDestructive: focusedHeaderAction?.isDestructive ?? false)
        }
    }

    private func clearServerFavoritesGroupAccessory(title: String, items: [FavoriteItem]) -> AnyView {
        let actionID = "server-favorites-clear-group-\(title)"
        let actionTitle = platformShellString("Clear Group")
        return AnyView(
            HStack(spacing: 14) {
                Button(action: {
                    clearTarget = .group(title: title, items: items)
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

                TVHeaderActionDescriptionText(text: actionDescription(for: actionID), width: 280, isDestructive: focusedHeaderAction?.isDestructive ?? false)
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



struct TVServerDownloadsDetailView: View {
    let server: ServerConfig

    @ObservedObject private var downloadCenter = DownloadCenterService.shared

    private var jobs: [DownloadJobGroup] {
        downloadCenter.jobs.filter { $0.serverId == server.id }
    }

    private var activeJobs: [DownloadJobGroup] {
        jobs.filter { $0.bucket == .active }
    }

    private var completedJobs: [DownloadJobGroup] {
        jobs.filter { $0.bucket == .completed }
    }

    private var failedJobs: [DownloadJobGroup] {
        jobs.filter { $0.bucket == .failed }
    }

    var body: some View {
        TVPageScrollView(
            title: platformShellString("Downloads"),
            subtitle: nil,
            handlesExitCommand: true
        ) {
            if jobs.isEmpty {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Empty Downloads Title"),
                    message: platformShellString("Platform Shell TV Empty Downloads Body"),
                    systemImageName: "arrow.down.circle"
                )
            } else {
                if !activeJobs.isEmpty {
                    TVDownloadJobListSection(
                        title: platformShellString("Active"),
                        jobs: activeJobs
                    )
                }

                if !completedJobs.isEmpty {
                    TVDownloadJobListSection(
                        title: platformShellString("Completed"),
                        jobs: completedJobs
                    )
                }

                if !failedJobs.isEmpty {
                    TVDownloadJobListSection(
                        title: platformShellString("Failed"),
                        jobs: failedJobs
                    )
                }
            }
        }
        .navigationTitle(Text(platformShellString("Downloads")))
    }
}
#endif
