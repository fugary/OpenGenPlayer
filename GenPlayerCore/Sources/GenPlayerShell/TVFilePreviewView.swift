#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVImagePreviewView: View {
    let initialFile: VideoFile
    let files: [VideoFile]
    let server: ServerConfig?

    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var previewFocusNamespace
    @State private var currentIndex: Int
    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?

    private var imageFiles: [VideoFile] {
        files.isEmpty ? [initialFile] : files
    }

    private var currentFile: VideoFile {
        guard imageFiles.indices.contains(currentIndex) else { return initialFile }
        return imageFiles[currentIndex]
    }

    init(initialFile: VideoFile, files: [VideoFile], server: ServerConfig? = nil) {
        self.initialFile = initialFile
        self.files = files
        self.server = server
        let startIndex = files.firstIndex(where: { $0.url == initialFile.url || $0.name == initialFile.name }) ?? 0
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 74)
                        .padding(.vertical, 96)
                } else if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.25)
                } else if let errorMessage {
                    TVFeedbackPanel(
                        title: platformShellString("Connection Failed"),
                        message: errorMessage,
                        systemImageName: "photo",
                        kind: .error,
                        tintColor: .red
                    )
                    .padding(.horizontal, 84)
                }
            }

            VStack {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tvDisplayTitle(for: currentFile))
                            .font(.title2.weight(.bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .frame(maxWidth: 900, alignment: .leading)

                        Text("\(currentIndex + 1) / \(imageFiles.count)")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white.opacity(0.58))
                    }

                    Spacer()

                    Button(action: close) {
                        TVCompactActionButton(
                            title: platformShellString("Close"),
                            systemImageName: "xmark"
                        )
                    }
                    .prefersDefaultFocus(true, in: previewFocusNamespace)
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
                .padding(.horizontal, 82)
                .padding(.top, 54)
                .tvFocusSectionIfAvailable()

                Spacer()

                if imageFiles.count > 1 {
                    HStack(spacing: 18) {
                        Button(action: showPreviousImage) {
                            TVImagePreviewStepButton(systemImageName: "chevron.left")
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                        .accessibilityLabel(Text(platformShellString("Back")))

                        Button(action: showNextImage) {
                            TVImagePreviewStepButton(systemImageName: "chevron.right")
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                        .accessibilityLabel(Text(platformShellString("Open")))
                    }
                    .padding(.bottom, 58)
                    .tvFocusSectionIfAvailable()
                }
            }
        }
        .navigationBarHidden(true)
        .focusScope(previewFocusNamespace)
        .onAppear {
            loadCurrentImage()
            requestPreviewFocus()
        }
        .onChange(of: currentIndex) { _ in
            loadedImage = nil
            errorMessage = nil
            loadCurrentImage()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        #if os(tvOS)
        .onExitCommand(perform: close)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                showPreviousImage()
            case .right:
                showNextImage()
            default:
                break
            }
        }
        #endif
    }

    private func resolvedServer(for file: VideoFile) -> ServerConfig? {
        if let server { return server }
        if let serverId = file.jellyfinServerId.flatMap(UUID.init(uuidString:)) {
            return AppNetworkService.shared.servers.first(where: { $0.id == serverId })
        }
        return nil
    }

    private func cacheKey(for file: VideoFile) -> String {
        let serverPrefix = resolvedServer(for: file)?.id.uuidString ?? file.jellyfinServerId ?? "local"
        return "tv_image_preview:\(serverPrefix):\(file.remoteDownloadPath)"
    }

    private func loadCurrentImage() {
        let file = currentFile
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil

        let key = cacheKey(for: file)
        if let cached = TVImageCache.shared.image(forKey: key) {
            loadedImage = cached
            isLoading = false
            return
        }

        let targetServer = resolvedServer(for: file)

        loadTask = Task {
            do {
                let localURL: URL
                let shouldCleanup: Bool
                if !file.isRemote && file.url.isFileURL && FileManager.default.fileExists(atPath: file.url.path) {
                    localURL = file.url
                    shouldCleanup = false
                } else if let targetServer {
                    localURL = try await AppNetworkService.shared.downloadFile(server: targetServer, at: file.remoteDownloadPath)
                    shouldCleanup = true
                } else if file.url.isFileURL && FileManager.default.fileExists(atPath: file.url.path) {
                    localURL = file.url
                    shouldCleanup = false
                } else {
                    throw URLError(.fileDoesNotExist)
                }

                defer {
                    if shouldCleanup {
                        tvCleanupTemporaryDownload(at: localURL)
                    }
                }

                try Task.checkCancellation()

                let decodedImage = (try? Data(contentsOf: localURL)).flatMap(UIImage.init(data:))
                    ?? UIImage(contentsOfFile: localURL.path)

                guard let image = decodedImage else {
                    throw URLError(.cannotDecodeContentData)
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    TVImageCache.shared.save(image, forKey: key)
                    loadedImage = image
                    isLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    loadedImage = nil
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func showPreviousImage() {
        guard imageFiles.count > 1 else { return }
        currentIndex = (currentIndex - 1 + imageFiles.count) % imageFiles.count
    }

    private func showNextImage() {
        guard imageFiles.count > 1 else { return }
        currentIndex = (currentIndex + 1) % imageFiles.count
    }

    private func close() {
        presentationMode.wrappedValue.dismiss()
    }

    private func requestPreviewFocus() {
        for delay in [0.0, 0.16, 0.36] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: previewFocusNamespace)
            }
        }
    }
}



struct TVImagePreviewStepButton: View {
    let systemImageName: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: systemImageName)
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(isFocused ? .black : .white.opacity(0.84))
            .frame(width: 74, height: 58)
            .background(
                Capsule(style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.94) : Color.white.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isFocused ? 0.18 : 0.10), lineWidth: 1)
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? Color.black.opacity(0.28) : .clear, radius: isFocused ? 16 : 0, x: 0, y: isFocused ? 8 : 0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}



enum TVFilePreviewMode {
    case text
    case unsupported
}



enum TVFilePreviewLoadState {
    case loading
    case text(String)
    case unsupported
    case failed(String)
}



struct TVFilePreviewView: View {
    let file: VideoFile
    let server: ServerConfig?

    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var previewFocusNamespace
    @State private var state: TVFilePreviewLoadState = .loading
    @State private var loadTask: Task<Void, Never>?

    private var previewMode: TVFilePreviewMode {
        if file.supportsTextPreview {
            return .text
        }
        return .unsupported
    }

    private var prefersCloseButtonFocus: Bool {
        switch state {
        case .text:
            return false
        case .loading, .unsupported, .failed:
            return true
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Group {
                    switch state {
                    case .loading:
                        VStack(spacing: 18) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                            Text(platformShellString("Platform Shell TV Preview Loading"))
                                .font(.headline.weight(.semibold))
                                .foregroundColor(.white.opacity(0.68))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    case .text(let content):
                        TVTextFilePreviewContent(text: content, focusNamespace: previewFocusNamespace)

                    case .unsupported:
                        unsupportedContent

                    case .failed(let message):
                        TVEmptyStateCard(
                            title: platformShellString("Couldn't open preview"),
                            message: message,
                            systemImageName: "doc.text.magnifyingglass"
                        )
                        .padding(.horizontal, 84)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .focusScope(previewFocusNamespace)
        .onAppear {
            loadPreview()
            requestPreviewFocus()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        #if os(tvOS)
        .onExitCommand(perform: close)
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tvDisplayTitle(for: file))
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(maxWidth: 980, alignment: .leading)

                Text(tvFilePreviewSubtitle)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.58))
            }

            Spacer()

            Button(action: close) {
                TVCompactActionButton(
                    title: platformShellString("Close"),
                    systemImageName: "xmark"
                )
            }
            .prefersDefaultFocus(prefersCloseButtonFocus, in: previewFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
        .padding(.horizontal, 82)
        .padding(.top, 54)
        .padding(.bottom, 30)
        .tvFocusSectionIfAvailable()
    }

    private var tvFilePreviewSubtitle: String {
        let typeName = tvMediaTypeTitle(for: file.type)
        let sizeText = file.size > 0 ? tvByteCountString(file.size) : nil
        if let sizeText {
            return "\(typeName) · \(sizeText)"
        }
        return typeName
    }

    private var unsupportedContent: some View {
        VStack(spacing: 24) {
            ZStack(alignment: .bottomTrailing) {
                TVPreviewFileIconTile(file: file, side: 136)

                ZStack {
                    Circle()
                        .fill(TVShellStyle.accentSoft)

                    Image(systemName: "ellipsis")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.black.opacity(0.82))
                }
                .frame(width: 42, height: 42)
                .offset(x: 8, y: 8)
            }

            Text(platformShellString("Preview Not Available"))
                .font(.system(size: 34, weight: .heavy))
                .foregroundColor(.white)

            Text(platformShellString("Platform Shell TV Preview Unsupported Body"))
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(.white.opacity(0.70))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 680)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 84)
        .padding(.bottom, 82)
    }

    private func loadPreview() {
        loadTask?.cancel()

        switch previewMode {
        case .unsupported:
            state = .unsupported

        case .text:
            state = .loading
            loadTask = Task {
                do {
                    let resolved = try await resolvedLocalURL()
                    defer {
                        if resolved.shouldCleanup {
                            tvCleanupTemporaryDownload(at: resolved.url)
                        }
                    }
                    if Task.isCancelled { return }

                    switch previewMode {
                    case .text:
                        let content = try readText(from: resolved.url)
                        if Task.isCancelled { return }
                        await MainActor.run {
                            state = .text(content)
                            requestPreviewFocus()
                        }

                    case .unsupported:
                        await MainActor.run {
                            state = .unsupported
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        state = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private var resolvedServer: ServerConfig? {
        if let server { return server }
        if let serverId = file.jellyfinServerId.flatMap(UUID.init(uuidString:)) {
            return AppNetworkService.shared.servers.first(where: { $0.id == serverId })
        }
        return nil
    }

    private func resolvedLocalURL() async throws -> (url: URL, shouldCleanup: Bool) {
        if !file.isRemote && file.url.isFileURL && FileManager.default.fileExists(atPath: file.url.path) {
            return (file.url, false)
        }
        guard let targetServer = resolvedServer else {
            if file.url.isFileURL && FileManager.default.fileExists(atPath: file.url.path) {
                return (file.url, false)
            }
            throw URLError(.fileDoesNotExist)
        }
        let downloadedURL = try await AppNetworkService.shared.downloadFile(server: targetServer, at: file.remoteDownloadPath)
        return (downloadedURL, true)
    }

    private func readText(from url: URL) throws -> String {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .windowsCP1252) {
            return content
        }
        return try String(contentsOf: url, encoding: .ascii)
    }

    private func close() {
        presentationMode.wrappedValue.dismiss()
    }

    private func requestPreviewFocus() {
        for delay in [0.0, 0.16, 0.36] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: previewFocusNamespace)
            }
        }
    }
}



struct TVTextFilePreviewContent: View {
    let text: String
    let focusNamespace: Namespace.ID
    @State private var scrollLine = 0

    private var lines: [String] {
        let splitLines = text.components(separatedBy: .newlines)
        return splitLines.isEmpty ? [" "] : splitLines
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 25, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.88))
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id(index)
                    }
                }
                .padding(.horizontal, 82)
                .padding(.vertical, 42)
            }
            .background(Color.white.opacity(0.045))
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tvFocusSectionIfAvailable()
            #if os(tvOS)
            .focusable(true)
            .prefersDefaultFocus(true, in: focusNamespace)
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    scrollLine = max(0, scrollLine - 10)
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(scrollLine, anchor: .top)
                    }
                case .down:
                    scrollLine = min(max(lines.count - 1, 0), scrollLine + 10)
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(scrollLine, anchor: .top)
                    }
                default:
                    break
                }
            }
            #endif
        }
    }
}



struct TVPreviewFileIconTile: View {
    let file: VideoFile
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            file.tvFileIconColor.opacity(0.36),
                            Color.white.opacity(0.08),
                            Color.black.opacity(0.22)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            Image(systemName: file.tvFileIconName)
                .font(.system(size: side * 0.38, weight: .semibold))
                .foregroundColor(file.tvFileIconColor)
        }
        .frame(width: side, height: side)
    }
}
#endif
