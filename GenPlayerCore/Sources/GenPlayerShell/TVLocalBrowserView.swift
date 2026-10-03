#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVLocalBrowserView: View {
    @Environment(\.tvBrowsingNavigation) private var browsingNavigation
    let rootTitle: String?
    let rootBoundaryURL: URL
    let stackParentURL: URL?
    let targetFileURL: URL?

    @Environment(\.resetFocus) private var resetFocus
    @ObservedObject private var securityService = TVSecurityService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    private let playbackCoordinator = TVPlaybackCoordinator.shared
    @Namespace private var fileFocusNamespace
    @State private var directoryURL: URL
    @State private var items: [VideoFile] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var didJumpToRootFolder = false
    @State private var focusedTargetFilePath: String?
    @State private var hasFocusedTargetFile = false
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingPrivatePlaybackFile: VideoFile?
    @State private var privacyUnlockTitle = platformShellString("Privacy Space")
    @State private var previewUnsupportedAlert: TVTransientAlert?
    @AppStorage("localFileFoldersOnTop") private var showsFoldersOnTop = true

    init(
        url: URL,
        rootTitle: String?,
        rootBoundaryURL: URL? = nil,
        stackParentURL: URL? = nil,
        targetFileURL: URL? = nil
    ) {
        let directoryURL = url.standardizedFileURL
        self.rootTitle = rootTitle
        self.rootBoundaryURL = (rootBoundaryURL ?? tvLocalBrowserRootBoundaryURL(for: directoryURL)).standardizedFileURL
        self.stackParentURL = stackParentURL?.standardizedFileURL
        let resolvedTargetFileURL = targetFileURL?.standardizedFileURL
        self.targetFileURL = resolvedTargetFileURL
        _directoryURL = State(initialValue: directoryURL)
    }

    private var sortedVisibleItems: [VideoFile] {
        tvSortVideoFiles(visibleItems, foldersOnTop: showsFoldersOnTop)
    }

    private var visibleItems: [VideoFile] {
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return items.filter { file in
            !file.name.hasPrefix(".") && !tvShouldHidePrivateFile(file)
        }
    }

    private var playableItems: [VideoFile] {
        visibleItems.filter { $0.type == .video || $0.type == .audio }
    }

    private var imageItems: [VideoFile] {
        visibleItems.filter { $0.type == .image }
    }

    private var displayTitle: String {
        if directoryURL.standardizedFileURL.path == rootBoundaryURL.standardizedFileURL.path {
            return rootTitle ?? platformShellString("Local")
        }
        return tvDisplayName(for: directoryURL)
    }

    private var breadcrumbSubtitle: String? {
        tvLocalFolderBreadcrumb(
            rootTitle: rootTitle ?? platformShellString("Local"),
            directoryURL: directoryURL,
            rootBoundaryURL: rootBoundaryURL
        )
    }

    private var parentURL: URL? {
        tvLocalParentURL(for: directoryURL, rootBoundaryURL: rootBoundaryURL)
    }

    private var parentFolderTitle: String {
        guard let parentURL else { return rootTitle ?? platformShellString("Local") }
        if parentURL.standardizedFileURL.path == rootBoundaryURL.standardizedFileURL.path {
            return rootTitle ?? platformShellString("Local")
        }
        return tvDisplayName(for: parentURL)
    }

    var body: some View {
        TVPageScrollView(
            title: displayTitle,
            subtitle: nil,
            handlesExitCommand: true,
            customExitCommand: handleLocalExitCommand,
            topPadding: 26,
            scrollTargetID: focusedTargetFilePath,
            showsHomeAction: parentURL != nil,
            customHomeAction: { returnToRootFolder() },
            showsDownloadsAction: true
        ) {
            if parentURL != nil {
                TVRemoteBrowserLocationBar(
                    pathText: breadcrumbSubtitle ?? (rootTitle ?? platformShellString("Local")),
                    parentTitle: parentFolderTitle,
                    onParent: { _ = returnToParentFolder() }
                )
                .tvFocusSectionIfAvailable()
            }

            if isLoading {
                TVLoadingCard()
            } else if let errorMessage {
                TVFeedbackPanel(
                    title: platformShellString("Platform Shell TV Remote Load Failed Title"),
                    message: errorMessage,
                    systemImageName: "folder.badge.questionmark",
                    kind: .error,
                    tintColor: .red,
                    action: TVFeedbackPanelAction(
                        title: platformShellString("Retry"),
                        systemImageName: "arrow.clockwise",
                        action: { loadContents(force: true) }
                    )
                )
            } else if visibleItems.isEmpty {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Folder Empty Title"),
                    message: platformShellString("Platform Shell TV Folder Empty Body"),
                    systemImageName: "folder"
                )
            } else {
                TVFileGridSection(
                    title: nil,
                    subtitle: nil,
                    itemType: .unknown,
                    items: sortedVisibleItems
                ) { item in
                    tvGridEntry(for: item)
                }
            }
        }
        .navigationTitle(Text(displayTitle))
        .focusScope(fileFocusNamespace)
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if TVSecurityService.shared.isPrivacySpaceUnlocked {
                handlePrivacyUnlockSuccess()
            }
        }) {
            TVPrivacyUnlockSheet(
                title: privacyUnlockTitle,
                isPresented: $isShowingPrivacyUnlock
            )
        }
        .onAppear {
            loadContents()
        }
        .alert(item: $previewUnsupportedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
    }

    @ViewBuilder
    private func tvGridEntry(for file: VideoFile) -> some View {
        let fileFocusID = tvLocalBrowserFocusID(for: file.url)
        let isTarget = isTargetFile(file)

        switch file.type {
        case .folder:
            TVNavigationLink(
                destination: TVPrivacyProtectedContent(
                    title: tvDisplayTitle(for: file),
                    isProtected: tvRequiresPrivacyAccess(file: file)
                ) {
                    TVLocalBrowserView(
                        url: file.url,
                        rootTitle: rootTitle,
                        rootBoundaryURL: rootBoundaryURL,
                        stackParentURL: directoryURL
                    )
                }
            ) {
                TVFileGridCard(file: file, privacyBadgeSystemName: privacyBadgeSystemName(for: file))
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTarget, in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

        case .video, .audio:
            Button(action: {
                playOrUnlock(file)
            }) {
                TVFileGridCard(file: file, privacyBadgeSystemName: privacyBadgeSystemName(for: file))
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTarget, in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

        case .image:
            TVNavigationLink(
                destination: TVPrivacyProtectedContent(
                    title: tvDisplayTitle(for: file),
                    isProtected: tvRequiresPrivacyAccess(file: file)
                ) {
                    TVImagePreviewView(initialFile: file, files: imageItems)
                }
            ) {
                TVFileGridCard(file: file, privacyBadgeSystemName: nil)
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTarget, in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

        case .subtitle, .document, .unknown:
            if file.supportsTextPreview {
                TVNavigationLink(
                    destination: TVPrivacyProtectedContent(
                        title: tvDisplayTitle(for: file),
                        isProtected: tvRequiresPrivacyAccess(file: file)
                    ) {
                        TVFilePreviewView(file: file, server: nil)
                    }
                ) {
                    TVFileGridCard(file: file, privacyBadgeSystemName: nil)
                }
                .id(fileFocusID)
                .prefersDefaultFocus(isTarget, in: fileFocusNamespace)
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            } else {
                Button(action: { showUnsupportedPreviewAlert(for: file) }) {
                    TVFileGridCard(file: file, privacyBadgeSystemName: nil)
                }
                .id(fileFocusID)
                .prefersDefaultFocus(isTarget, in: fileFocusNamespace)
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }

    private func loadContents(force: Bool = false) {
        loadContents(force: force, at: directoryURL)
    }

    private func loadContents(force: Bool = false, at targetURL: URL) {
        let targetURL = targetURL.standardizedFileURL
        guard force || (!isLoading && items.isEmpty && errorMessage == nil) else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let loaded = try tvLoadLocalDirectoryContents(at: targetURL)
                await MainActor.run {
                    guard directoryURL.standardizedFileURL.path == targetURL.path else { return }
                    items = sortVideoFiles(loaded)
                    isLoading = false
                    activateTargetFileFocusIfNeeded(loadedItems: items)
                }
            } catch {
                await MainActor.run {
                    guard directoryURL.standardizedFileURL.path == targetURL.path else { return }
                    items = []
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func playablePlaylist(for file: VideoFile) -> [VideoFile] {
        visibleItems
            .filter { $0.type == file.type || $0.type == .subtitle }
            .map { tvPlayableFile(from: $0, downloadCenter: downloadCenter) ?? $0 }
    }

    private func playOrUnlock(_ file: VideoFile) {
        if tvRequiresPrivacyAccess(file: file) {
            pendingPrivatePlaybackFile = file
            privacyUnlockTitle = tvDisplayTitle(for: file)
            isShowingPrivacyUnlock = true
            return
        }

        let playableFile = tvPlayableFile(from: file, downloadCenter: downloadCenter) ?? file
        playbackCoordinator.play(file: playableFile, playlist: playablePlaylist(for: file))
    }

    private func showUnsupportedPreviewAlert(for file: VideoFile) {
        previewUnsupportedAlert = TVTransientAlert(
            title: platformShellString("Preview Not Available"),
            message: platformShellString("Platform Shell TV Preview Unsupported Body")
        )
    }

    private func handlePrivacyUnlockSuccess() {
        if let pendingPrivatePlaybackFile {
            self.pendingPrivatePlaybackFile = nil
            let playableFile = tvPlayableFile(from: pendingPrivatePlaybackFile, downloadCenter: downloadCenter) ?? pendingPrivatePlaybackFile
            playbackCoordinator.play(file: playableFile, playlist: playablePlaylist(for: pendingPrivatePlaybackFile))
        }
    }

    private func privacyBadgeSystemName(for file: VideoFile) -> String? {
        guard file.type == .folder,
              PrivacySpaceService.shared.isFileMarkedPrivate(file),
              securityService.isPrivacySpaceEnabled || !securityService.hasPrivacyPassword else {
            return nil
        }
        return securityService.hasPrivacyPassword && securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock"
    }

    private func isTargetFile(_ file: VideoFile) -> Bool {
        guard let focusedTargetFilePath else { return false }
        let target = URL(fileURLWithPath: focusedTargetFilePath).standardizedFileURL.path.lowercased()
        let current = file.url.standardizedFileURL.path.lowercased()
        if target == current { return true }
        let targetName = URL(fileURLWithPath: target).lastPathComponent
        let currentName = URL(fileURLWithPath: current).lastPathComponent
        return !targetName.isEmpty && targetName == currentName
    }

    private func activateTargetFileFocusIfNeeded(loadedItems: [VideoFile]) {
        guard !hasFocusedTargetFile,
              let targetFileURL else {
            return
        }

        let target = targetFileURL.standardizedFileURL.path.lowercased()
        let match = loadedItems.first { file in
            let current = file.url.standardizedFileURL.path.lowercased()
            if target == current { return true }
            let targetName = URL(fileURLWithPath: target).lastPathComponent
            let currentName = URL(fileURLWithPath: current).lastPathComponent
            return !targetName.isEmpty && targetName == currentName
        }

        guard let matchedFile = match else { return }

        hasFocusedTargetFile = true
        focusedTargetFilePath = matchedFile.url.standardizedFileURL.path
        requestTargetFileFocus()
    }

    private func requestTargetFileFocus() {
        for delay in [0.0, 0.12, 0.35, 0.70] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: fileFocusNamespace)
            }
        }
    }

    private func handleLocalExitCommand() -> Bool {
        if directoryURL.standardizedFileURL.path == rootBoundaryURL.standardizedFileURL.path, didJumpToRootFolder {
            didJumpToRootFolder = false
            if tvPopToRootNavigationIfPossible(in: browsingNavigation) {
                return true
            }
        }

        return returnToParentFolder()
    }

    @discardableResult
    private func returnToParentFolder() -> Bool {
        guard let parentURL else { return false }

        if stackParentURL?.standardizedFileURL.path == parentURL.standardizedFileURL.path,
           tvPopNavigationIfPossible(in: browsingNavigation) {
            return true
        }

        directoryURL = parentURL
        items = []
        errorMessage = nil
        isLoading = false
        focusedTargetFilePath = nil
        loadContents(force: true, at: parentURL)
        return true
    }

    private func returnToRootFolder() {
        directoryURL = rootBoundaryURL
        didJumpToRootFolder = true
        items = []
        errorMessage = nil
        isLoading = false
        focusedTargetFilePath = nil
        loadContents(force: true, at: rootBoundaryURL)
    }
}
#endif
