#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

final class MacPreviewLoadingState: ObservableObject {
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var requestID: UUID?

    func begin() -> UUID {
        let id = UUID()
        requestID = id
        errorMessage = nil
        isLoading = true
        return id
    }

    @discardableResult
    func finish(_ id: UUID, error: String? = nil) -> Bool {
        guard requestID == id else { return false }
        requestID = nil
        isLoading = false
        errorMessage = error
        return true
    }

    func reset() {
        requestID = nil
        isLoading = false
        errorMessage = nil
    }
}

class MacPreviewWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacPreviewWindowManager()
    private var window: NSWindow?
    private var onCloseCallback: (() -> Void)?
    private var isClosing = false
    private var currentURL: URL?
    private let loadingState = MacPreviewLoadingState()

    func beginLoadingPreview(replacing url: URL) -> UUID? {
        guard window != nil, currentURL == url, !loadingState.isLoading else { return nil }
        return loadingState.begin()
    }

    func finishLoadingPreview(_ requestID: UUID, error: String? = nil) -> Bool {
        loadingState.finish(requestID, error: error)
    }

    func openPreview(url: URL, file: VideoFile, onPrevious: (() -> Void)?, onNext: (() -> Void)?, onClose: @escaping () -> Void) {
        loadingState.reset()
        currentURL = url
        self.onCloseCallback = onClose
        let view = MacFilePreviewSheet(url: url, file: file, loadingState: loadingState, onPrevious: onPrevious, onNext: onNext) { [weak self] in
            self?.close()
        }

        if let existingWindow = window {
            existingWindow.contentView = NSHostingView(rootView: view)
            existingWindow.title = file.name
            existingWindow.makeKeyAndOrderFront(nil)
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            newWindow.title = file.name
            newWindow.titlebarAppearsTransparent = true
            newWindow.isMovableByWindowBackground = true
            newWindow.tabbingMode = .disallowed
            newWindow.delegate = self
            newWindow.contentView = NSHostingView(rootView: view)
            newWindow.makeKeyAndOrderFront(nil)
            self.window = newWindow
        }
    }

    func close() {
        guard !isClosing else { return }
        loadingState.reset()
        currentURL = nil
        isClosing = true
        defer { isClosing = false }

        if let win = window {
            self.window = nil
            win.delegate = nil
            win.contentView = nil
            win.close()
        }
        let callback = onCloseCallback
        onCloseCallback = nil
        callback?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        loadingState.reset()
        currentURL = nil
        isClosing = true
        defer { isClosing = false }

        if let win = window {
            self.window = nil
            win.delegate = nil
            win.contentView = nil
        }
        let callback = onCloseCallback
        onCloseCallback = nil
        callback?()
    }
}
#endif
