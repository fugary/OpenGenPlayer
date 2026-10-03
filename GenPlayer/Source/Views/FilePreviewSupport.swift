import SwiftUI
#if os(iOS)
import UIKit
#endif
import QuickLook

enum FilePreviewRoute {
    case image
    case text
    case quickLook
    case openElsewhere
    case unavailable

    private static let quickLookExtensions: Set<String> = [
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "rtf", "pages", "numbers", "key"
    ]

    static func supportsQuickLook(for url: URL) -> Bool {
        quickLookExtensions.contains(url.pathExtension.lowercased())
    }
}

extension VideoFile {
    var previewRoute: FilePreviewRoute {
        switch type {
        case .image:
            return .image
        case .subtitle:
            return supportsTextPreview ? .text : .openElsewhere
        case .document:
            if supportsTextPreview {
                return .text
            }
            if FilePreviewRoute.supportsQuickLook(for: url) {
                return .quickLook
            }
            return .openElsewhere
        case .unknown:
            if FilePreviewRoute.supportsQuickLook(for: url) {
                return .quickLook
            }
            return .openElsewhere
        case .folder, .audio, .video:
            return .unavailable
        }
    }

    var canOpenInPreviewSheet: Bool {
        switch previewRoute {
        case .image, .text, .quickLook, .openElsewhere:
            return true
        case .unavailable:
            return false
        }
    }
}

struct FilePreviewContentView: View {
    let file: VideoFile
    var imagePlaylist: [VideoFile]? = nil
    var imageContextFiles: [VideoFile]? = nil
    var networkService: AppNetworkService? = nil
    var server: ServerConfig? = nil
    var isImageIsolated: Bool = false

    @ViewBuilder
    var body: some View {
        switch file.previewRoute {
        case .image:
            ImagePreviewView(
                initialFile: file,
                isIsolated: isImageIsolated,
                contextFiles: imageContextFiles,
                playlist: imagePlaylist,
                networkService: networkService,
                server: server
            )
        case .text:
            TextPreviewView(file: file)
        case .quickLook:
            DocumentPreviewView(file: file)
        case .openElsewhere:
            ExternalOpenPromptView(file: file)
        case .unavailable:
            UnsupportedPreviewView()
        }
    }
}

struct DocumentPreviewView: View {
    let file: VideoFile

    @State private var isPresentingShareSheet = false

    var body: some View {
        Group {
            if file.url.isFileURL {
                QuickLookPreviewController(fileURL: file.url)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                UnsupportedPreviewView()
            }
        }
        .navigationBarTitle(file.name, displayMode: .inline)
        .navigationBarItems(trailing: shareButton)
        .sheet(isPresented: $isPresentingShareSheet) {
            ActivityShareSheet(activityItems: [file.url])
        }
    }

    private var shareButton: some View {
        Button(action: {
            isPresentingShareSheet = true
        }) {
            AppToolbarIcon(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(Text(NSLocalizedString("Open in Another App", comment: "")))
    }
}

private struct ExternalOpenPromptContent: View {
    let file: VideoFile
    var isPrimaryActionInProgress: Bool = false
    let primaryAction: () -> Void

    private var actionTint: Color {
        file.usesStyledFormatTile ? file.iconColor : Color(UIColor.systemBlue)
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack(alignment: .bottomTrailing) {
                    if file.usesStyledFormatTile {
                        FileFormatIconView(file: file, side: 108)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color(UIColor.secondarySystemBackground))

                            Image(systemName: file.iconName)
                                .font(.system(size: 50, weight: .regular))
                                .foregroundColor(file.iconColor)
                        }
                        .frame(width: 108, height: 108)
                    }

                    ZStack {
                        Circle()
                            .fill(actionTint)

                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 38, height: 38)
                    .shadow(color: actionTint.opacity(0.22), radius: 10, x: 0, y: 5)
                    .offset(x: 6, y: 6)
                }

                Text(NSLocalizedString("Preview Not Available", comment: ""))
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(NSLocalizedString("This file type isn't supported for in-app preview yet.", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button(action: primaryAction) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.white.opacity(0.16))

                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Open in Another App", comment: ""))
                                .font(.headline)
                                .foregroundColor(.white)

                            Text(NSLocalizedString("Choose Word, Excel, Files, or another installed app.", comment: ""))
                                .font(.subheadline)
                                .foregroundColor(Color.white.opacity(0.82))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        if isPrimaryActionInProgress {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.88))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(actionTint)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: actionTint.opacity(0.16), radius: 12, x: 0, y: 6)
                }
                .disabled(isPrimaryActionInProgress)
                .padding(.horizontal, 24)
            }
            .frame(maxWidth: 420)
            .padding(.vertical, 32)
        }
    }
}

struct ExternalOpenPromptView: View {
    let file: VideoFile

    @State private var isPresentingShareSheet = false

    var body: some View {
        ExternalOpenPromptContent(file: file) {
            isPresentingShareSheet = true
        }
        .navigationBarTitle(file.name, displayMode: .inline)
        .sheet(isPresented: $isPresentingShareSheet) {
            ActivityShareSheet(activityItems: [file.url])
        }
    }
}

struct DeferredExternalOpenPromptView: View {
    let file: VideoFile
    let downloadedURL: URL?
    let isDownloading: Bool
    let startDownload: () -> Void

    @State private var isPresentingShareSheet = false

    var body: some View {
        ExternalOpenPromptContent(
            file: file,
            isPrimaryActionInProgress: isDownloading
        ) {
            if downloadedURL != nil {
                isPresentingShareSheet = true
            } else {
                startDownload()
            }
        }
        .navigationBarTitle(file.name, displayMode: .inline)
        .onChange(of: downloadedURL) { newValue in
            if newValue != nil {
                isPresentingShareSheet = true
            }
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            if let downloadedURL = downloadedURL {
                ActivityShareSheet(activityItems: [downloadedURL])
            }
        }
    }
}

struct ResolvedRemoteFilePreviewLoader: View {
    let file: VideoFile
    @ObservedObject private var settings = AppSettings.shared

    @State private var downloadedURL: URL?
    @State private var isDownloading: Bool
    @State private var errorMessage: String?
    @State private var downloadTask: Task<Void, Never>?

    init(file: VideoFile) {
        self.file = file
        _isDownloading = State(initialValue: file.previewRoute != .openElsewhere)
    }

    var body: some View {
        Group {
            if requiresExplicitUserDownload {
                DeferredExternalOpenPromptView(
                    file: file,
                    downloadedURL: downloadedURL,
                    isDownloading: isDownloading,
                    startDownload: startDownloadIfNeeded
                )
            } else if let downloadedURL {
                FilePreviewContentView(
                    file: localPreviewFile(from: downloadedURL),
                    isImageIsolated: true
                )
            } else {
                Group {
                    if errorMessage == nil && isDownloading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(NSLocalizedString("Downloading...", comment: ""))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Color(UIColor.systemBackground)
                            .ignoresSafeArea()
                    }
                }
                .onAppear {
                    if downloadedURL == nil && errorMessage == nil && isDownloading {
                        startDownloadIfNeeded()
                    }
                }
            }
        }
        .navigationBarTitle(file.name, displayMode: .inline)
        .onDisappear(perform: cancelDownload)
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't open preview", comment: "")
        )
    }

    private var resolvedServer: ServerConfig? {
        file.resolvedServer
    }

    private var requiresExplicitUserDownload: Bool {
        file.previewRoute == .openElsewhere
    }

    private func localPreviewFile(from url: URL) -> VideoFile {
        VideoFile(
            name: file.name,
            url: url,
            type: file.type,
            size: file.size,
            date: file.date
        )
    }

    private func startDownloadIfNeeded() {
        guard downloadTask == nil else { return }
        downloadFile()
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func downloadFile() {
        guard let server = resolvedServer else {
            errorMessage = NSLocalizedString("Couldn't open preview", comment: "")
            isDownloading = false
            return
        }

        guard server.type.supportsRemoteFileDownload else {
            errorMessage = NSLocalizedString("Preview is not supported for this server type yet.", comment: "")
            isDownloading = false
            return
        }

        isDownloading = true
        downloadTask = Task {
            do {
                let localURL: URL
                if settings.enableRemoteFileCache {
                    localURL = try await RemoteFileCacheService.shared.fetchFile(
                        server: server,
                        remotePath: file.remoteDownloadPath,
                        fileName: file.name
                    )
                } else {
                    localURL = try await AppNetworkService.shared.downloadFile(server: server, at: file.remoteDownloadPath)
                }
                await MainActor.run {
                    downloadedURL = localURL
                    isDownloading = false
                    downloadTask = nil
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadTask = nil
                    guard !isCancellation(error), !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct QuickLookPreviewController: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> QuickLookPreviewCoordinator {
        QuickLookPreviewCoordinator(fileURL: fileURL)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.fileURL = fileURL
        uiViewController.reloadData()
    }
}

private final class QuickLookPreviewCoordinator: NSObject, QLPreviewControllerDataSource {
    var fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        fileURL as NSURL
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
