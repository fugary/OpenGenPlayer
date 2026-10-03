#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


enum TVStoredMediaDestinationIntent: String {
    case revealParent
    case openItem
}



struct TVStoredMediaPresentation: Identifiable {
    let file: VideoFile
    let intent: TVStoredMediaDestinationIntent

    var id: String {
        "\(file.url.absoluteString)-\(intent.rawValue)"
    }
}



struct TVStoredMediaNavigationLink<Label: View>: View {
    let file: VideoFile
    let intent: TVStoredMediaDestinationIntent
    let label: () -> Label

    @ObservedObject private var presentationManager = TVStoredMediaPresentationManager.shared

    init(
        file: VideoFile,
        intent: TVStoredMediaDestinationIntent,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.file = file
        self.intent = intent
        self.label = label
    }

    private var resolvedServer: ServerConfig? {
        file.tvResolvedServer(from: AppNetworkService.shared.servers)
    }

    private var usesFullScreenPresentation: Bool {
        if tvShouldUseLocalFolderBrowser(for: file, intent: intent) {
            return true
        }

        guard let server = resolvedServer else { return false }
        if server.type.tvIsMediaLibraryServer {
            return file.isRemote || tvPreferredLibraryTargetItemId(for: file) != nil
        }
        if server.type.tvSupportsFileBrowsing {
            return file.isRemote || tvTrimmedText(file.serverPath) != nil
        }
        if server.type == .iptv {
            return true
        }
        return false
    }

    var body: some View {
        Group {
            if usesFullScreenPresentation {
                Button(action: {
                    presentationManager.presentation = TVStoredMediaPresentation(file: file, intent: intent)
                }) {
                    label()
                }
            } else {
                NavigationLink(
                    destination: TVPrivacyProtectedContent(
                        title: tvDisplayTitle(for: file),
                        isProtected: tvRequiresPrivacyAccess(file: file)
                    ) {
                        TVMediaDetailView(file: file)
                    }
                ) {
                    label()
                }
            }
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVStoredMediaPresentationRoot: View {
    let file: VideoFile
    let intent: TVStoredMediaDestinationIntent

    @ObservedObject private var networkService = AppNetworkService.shared

    private var resolvedServer: ServerConfig? {
        file.tvResolvedServer(from: networkService.servers)
    }

    var body: some View {
        Group {
            TVPrivacyProtectedContent(
                title: tvDisplayTitle(for: file),
                isProtected: tvRequiresPrivacyAccess(file: file)
            ) {
                presentedDestination
            }
        }
        .background(TVShellStyle.background.ignoresSafeArea())
        .tvApplyAppTheme()
    }

    @ViewBuilder
    private var presentedDestination: some View {
        if tvShouldUseLocalFolderBrowser(for: file, intent: intent) {
            TVLocalBrowserView(
                url: tvLocalFolderNavigationURL(for: file, intent: intent),
                rootTitle: platformShellString("Local"),
                targetFileURL: tvLocalFolderTargetFileURL(for: file, intent: intent)
            )
        } else if let server = resolvedServer,
           file.isRemote ||
           tvTrimmedText(file.serverPath) != nil ||
           (server.type.tvIsMediaLibraryServer && tvPreferredLibraryTargetItemId(for: file) != nil) ||
           server.type == .iptv {
            if server.type.tvIsMediaLibraryServer {
                TVMediaLibraryBrowserView(
                    server: server,
                    title: server.name,
                    parentNode: nil,
                    targetItemIdToResolve: tvPreferredLibraryTargetItemId(for: file),
                    targetFallbackFile: file
                )
            } else if server.type.tvSupportsFileBrowsing {
                TVRemoteBrowserView(
                    server: server,
                    path: tvRemoteFolderNavigationPath(for: file, intent: intent),
                    rootTitle: tvDisplayTitle(for: file),
                    targetFilePath: tvRemoteFolderTargetFilePath(for: file, intent: intent)
                )
            } else if server.type == .iptv {
                TVIPTVPlaylistView(server: server, onExit: {
                    TVStoredMediaPresentationManager.shared.presentation = nil
                })
            } else {
                TVMediaDetailView(file: file)
            }
        } else {
            TVMediaDetailView(file: file)
        }
    }
}
#endif
