#if os(macOS)
import AppKit
import SwiftUI
import GenPlayerCore

public protocol MacPlaylistResolver {
    func resolvePlaylist(for file: VideoFile) async -> [VideoFile]?
}

public class MacPlayerWindowManager: ObservableObject {
    public static let shared = MacPlayerWindowManager()
    
    public var playlistResolver: MacPlaylistResolver? = MacDefaultPlaylistResolver()
    
    @Published public var activeWindows: [String: NSWindowController] = [:]
    @Published public var activeFiles: [String: VideoFile] = [:]
    @Published public var activePlaybackServices: [String: MacVLCPlaybackService] = [:]
    
    // Maintain backwards compatibility and track the "most recently active" session
    @Published public var currentPlayerWindowController: NSWindowController?
    @Published public var currentPlayerFileId: String?
    @Published public var currentPlayingFile: VideoFile?
    @Published public var currentPlaybackService: MacVLCPlaybackService?
    
    public var mainWindow: NSWindow?
    private var mainWindowDelegate: MacMainWindowDelegate?
    public var isOpeningExternalFile: Bool = false
    
    @Published public var activeMiniPlayerFileIds: Set<String> = []
    private var preMiniPlayerFrames: [String: NSRect] = [:]
    private var preMiniPlayerLevels: [String: NSWindow.Level] = [:]
    private var preZoomFrames: [String: NSRect] = [:]
    
    public func isMiniPlayer(for fileId: String) -> Bool {
        return activeMiniPlayerFileIds.contains(fileId)
    }
    
    private init() {
    }
    
    private func rankedSubtitleURLs(_ urls: [URL], for videoName: String) -> [URL] {
        let scored = urls.compactMap { url -> (url: URL, score: Int)? in
            let subtitleName = url.deletingPathExtension().lastPathComponent.lowercased()
            if subtitleName == videoName {
                return (url, 100)
            } else if subtitleName.hasPrefix(videoName) {
                return (url, 90)
            } else {
                return (url, 10)
            }
        }.sorted { $0.score > $1.score }
        return scored.map { $0.url }
    }
    
    private func attachSidecarSubtitles(to video: VideoFile, using subtitleURLs: [URL]) -> VideoFile {
        guard video.externalSubtitleCandidates.isEmpty else { return video }
        let videoName = video.url.deletingPathExtension().lastPathComponent.lowercased()
        let ranked = rankedSubtitleURLs(subtitleURLs, for: videoName)
        let candidates = ranked.map { ExternalSubtitleCandidate(url: $0, displayName: $0.deletingPathExtension().lastPathComponent) }
        var mutable = video
        mutable.externalSubtitleCandidates = candidates
        return mutable
    }
    
    private func findLocalSubtitleURLs(for videoURL: URL) -> [URL] {
        guard videoURL.isFileURL else { return [] }
        let directoryURL = videoURL.deletingLastPathComponent()
        let videoName = videoURL.deletingPathExtension().lastPathComponent
        
        var urls: [URL] = []
        if self.isOpeningExternalFile {
            // We only have permission for the specific file. We can't use contentsOfDirectory without a prompt.
            // Try specific exact match subtitles:
            for ext in VideoFile.FileType.subtitleExtensions {
                let subURL = directoryURL.appendingPathComponent("\(videoName).\(ext)")
                if FileManager.default.isReadableFile(atPath: subURL.path) {
                    urls.append(subURL)
                }
            }
        } else {
            let subtitleExtensions = Set(VideoFile.FileType.subtitleExtensions)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            urls = contents.filter { subtitleExtensions.contains($0.pathExtension.lowercased()) }
        }
        return urls
    }
    
    public func openPlayer(for file: VideoFile, playlist: [VideoFile]? = nil, thumbnailURL: URL? = nil) {
        if !file.isRemote && file.url.isFileURL {
            _ = MacLocalFolderBookmarkService.shared.ensureAccess(for: file.url)
        }

        if file.isRemote, (file.serverType?.requiresDynamicPlaybackURL == true),
           file.url.isFileURL || file.serverPath?.isEmpty == false {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let resolvedFile = try await AppNetworkService.shared.resolvedPlaybackFile(file)
                    self.openPlayerDirectly(for: resolvedFile, playlist: playlist, thumbnailURL: thumbnailURL)
                } catch {
                    print("[MacPlayerWindowManager] Failed to resolve dynamic playback URL for \(file.name): \(error.localizedDescription)")
                    self.openPlayerDirectly(for: file, playlist: playlist, thumbnailURL: thumbnailURL)
                }
            }
            return
        }

        openPlayerDirectly(for: file, playlist: playlist, thumbnailURL: thumbnailURL)
    }

    private func openPlayerDirectly(for file: VideoFile, playlist: [VideoFile]? = nil, thumbnailURL: URL? = nil) {
        // If trying to open a file that already has a window, just bring it to front
        let fileId = file.id
        let matchedController = activeWindows[fileId] ?? activeWindows.first(where: {
            if let activeFile = activeFiles[$0.key] {
                if let path = file.serverPath, let activePath = activeFile.serverPath, !path.isEmpty {
                    return path == activePath
                }
            }
            return false
        })?.value
        if let existingController = matchedController, let window = existingController.window {
            window.makeKeyAndOrderFront(nil)
            currentPlayerWindowController = existingController
            currentPlayerFileId = fileId
            return
        }

        var subtitleURLs: [URL] = []
        if let p = playlist {
            let subtitleExtensions = Set(VideoFile.FileType.subtitleExtensions)
            subtitleURLs = p.filter { subtitleExtensions.contains($0.url.pathExtension.lowercased()) }.map { $0.url }
        }
        
        if subtitleURLs.isEmpty && file.url.isFileURL && !file.isRemote {
            subtitleURLs = findLocalSubtitleURLs(for: file.url)
        }
        
        var mutableFile = attachSidecarSubtitles(to: file, using: subtitleURLs)
        var filteredPlaylist = playlist?.filter { $0.type == .video || $0.type == .audio }
        if var p = filteredPlaylist {
            for i in 0..<p.count {
                p[i] = attachSidecarSubtitles(to: p[i], using: subtitleURLs)
                if p[i].id == mutableFile.id {
                    mutableFile = p[i]
                } else if p[i].serverPath != nil && p[i].serverPath == mutableFile.serverPath {
                    mutableFile.externalSubtitleCandidates = p[i].externalSubtitleCandidates
                }
            }
            filteredPlaylist = p
        }
        
        let playerView = MacPlayerSheet(initialFile: mutableFile, playlist: filteredPlaylist, thumbnailURL: thumbnailURL, onDismiss: { [weak self] in
            self?.closePlayer(for: mutableFile.id)
        })
        .preferredColorScheme(.dark)
        
        let hostingController = NSHostingController(rootView: playerView)
        let enableMultiWindow = UserDefaults.standard.object(forKey: "enableMacMultiWindow") as? Bool ?? true
        var frameToRestore: NSRect? = nil
        var wasFloating: Bool = false
        var wasFullscreen: Bool = false
        var wasMiniPlayer: Bool = false
        
        if !enableMultiWindow {
            if let existingController = currentPlayerWindowController, let window = existingController.window {
                frameToRestore = window.frame
                wasFloating = window.level == .floating
                wasFullscreen = window.styleMask.contains(.fullScreen)
                if let oldId = currentPlayerFileId {
                    wasMiniPlayer = isMiniPlayer(for: oldId)
                    closePlayer(for: oldId)
                }
            }
            closeOtherWindows(except: "close_all")
        }
        
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let defaultWidth: CGFloat = min(1120, max(880, screenFrame.width * 0.62)).rounded()
        let defaultHeight: CGFloat = (defaultWidth / (16.0 / 9.0)).rounded()
        let defaultSize = NSSize(width: defaultWidth, height: defaultHeight)

        let isAudio = mutableFile.type == .audio
        let standardMinSize = isAudio ? NSSize(width: 480, height: 260) : NSSize(width: 560, height: 320)

        let initialX = (screenFrame.midX - defaultWidth / 2).rounded()
        let initialY = (screenFrame.midY - defaultHeight / 2).rounded()

        let window = NSWindow(
            contentRect: NSRect(x: initialX, y: initialY, width: defaultWidth, height: defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = standardMinSize
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        
        var targetFrame: NSRect
        let savedAlwaysOnTop = UserDefaults.standard.bool(forKey: "macPlayerAlwaysOnTop")
        if wasMiniPlayer {
            activeMiniPlayerFileIds.insert(mutableFile.id)
            window.level = .floating
            window.styleMask.remove([.closable, .miniaturizable, .resizable])
            window.minSize = isAudio ? NSSize(width: 280, height: 88) : NSSize(width: 320, height: 180)
            let miniSize = isAudio ? NSSize(width: 320, height: 88) : NSSize(width: 400, height: 225)
            if let frame = frameToRestore {
                targetFrame = NSRect(x: frame.minX, y: frame.minY, width: miniSize.width, height: miniSize.height)
            } else {
                targetFrame = NSRect(x: initialX, y: initialY, width: miniSize.width, height: miniSize.height)
            }
            setWindowTitleBarButtonsHidden(true, for: mutableFile.id)
        } else if let frame = frameToRestore {
            targetFrame = frame
            if wasFloating || savedAlwaysOnTop {
                window.level = .floating
            }
        } else if let lastWindow = activeWindows.values.first?.window {
            var frame = lastWindow.frame
            frame.origin.x += 30
            frame.origin.y -= 30
            targetFrame = frame
            if savedAlwaysOnTop {
                window.level = .floating
            }
        } else {
            targetFrame = NSRect(x: initialX, y: initialY, width: defaultWidth, height: defaultHeight)
            if savedAlwaysOnTop {
                window.level = .floating
            }
        }
        
        window.title = mutableFile.name
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)

        // Ensure window size is locked to expected target frame after NSHostingController attachment
        window.setFrame(targetFrame, display: true)
        if frameToRestore == nil && activeWindows.isEmpty && !wasMiniPlayer {
            window.center()
        }
        
        // Hide title bar to make it look like a modern player
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        
        let windowController = NSWindowController(window: window)
        activeWindows[mutableFile.id] = windowController
        activeFiles[mutableFile.id] = mutableFile
        
        currentPlayerWindowController = windowController
        currentPlayerFileId = mutableFile.id
        currentPlayingFile = mutableFile
        
        windowController.showWindow(nil)
        
        if wasFullscreen {
            window.toggleFullScreen(nil)
        }
        
        // Observe window close to clean up
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let closingWindow = notification.object as? NSWindow else { return }
            if let closedId = self.activeWindows.first(where: { $1.window === closingWindow })?.key {
                closingWindow.contentViewController = nil
                self.preMiniPlayerFrames.removeValue(forKey: closedId)
                self.preMiniPlayerLevels.removeValue(forKey: closedId)
                self.preZoomFrames.removeValue(forKey: closedId)
                self.activeMiniPlayerFileIds.remove(closedId)
                self.activeWindows.removeValue(forKey: closedId)
                self.activeFiles.removeValue(forKey: closedId)
                self.activePlaybackServices.removeValue(forKey: closedId)
                if self.currentPlayerFileId == closedId {
                    self.currentPlayerWindowController = nil
                    self.currentPlayerFileId = nil
                    self.currentPlayingFile = nil
                    
                    if let fallback = self.activeWindows.first {
                        self.currentPlayerWindowController = fallback.value
                        self.currentPlayerFileId = fallback.key
                    }
                }
            }
        }
    }
    
    public func closePlayer(for fileId: String) {
        if let wc = activeWindows[fileId] {
            wc.window?.contentViewController = nil
            wc.close()
            preMiniPlayerFrames.removeValue(forKey: fileId)
            preMiniPlayerLevels.removeValue(forKey: fileId)
            preZoomFrames.removeValue(forKey: fileId)
            activeMiniPlayerFileIds.remove(fileId)
            activeWindows.removeValue(forKey: fileId)
            activeFiles.removeValue(forKey: fileId)
            activePlaybackServices.removeValue(forKey: fileId)
        }
        
        if currentPlayerFileId == fileId {
            currentPlayerWindowController = nil
            currentPlayerFileId = nil
            currentPlayingFile = nil
            if let fallback = activeWindows.first {
                currentPlayerWindowController = fallback.value
                currentPlayerFileId = fallback.key
            }
        }
    }
    
    public func updatePlayingFile(from oldFileId: String, to newFile: VideoFile, playbackService: MacVLCPlaybackService? = nil) {
        if let wc = activeWindows.removeValue(forKey: oldFileId) {
            activeWindows[newFile.id] = wc
            wc.window?.title = newFile.name
        }
        activeFiles.removeValue(forKey: oldFileId)
        activeFiles[newFile.id] = newFile
        
        if let ps = activePlaybackServices.removeValue(forKey: oldFileId) ?? playbackService {
            activePlaybackServices[newFile.id] = ps
        }
        
        if let frame = preMiniPlayerFrames.removeValue(forKey: oldFileId) {
            preMiniPlayerFrames[newFile.id] = frame
        }
        if let level = preMiniPlayerLevels.removeValue(forKey: oldFileId) {
            preMiniPlayerLevels[newFile.id] = level
        }
        if let zoom = preZoomFrames.removeValue(forKey: oldFileId) {
            preZoomFrames[newFile.id] = zoom
        }
        if activeMiniPlayerFileIds.contains(oldFileId) {
            activeMiniPlayerFileIds.remove(oldFileId)
            activeMiniPlayerFileIds.insert(newFile.id)
        }
        
        if currentPlayerFileId == oldFileId || currentPlayerFileId == nil {
            currentPlayerFileId = newFile.id
            currentPlayingFile = newFile
            if let wc = activeWindows[newFile.id] {
                currentPlayerWindowController = wc
            }
            if let ps = activePlaybackServices[newFile.id] {
                currentPlaybackService = ps
            }
        }
    }
    
    public func fitWindowToVideoAspectRatio(fileId: String, videoSize: CGSize) {
        guard videoSize.width > 1, videoSize.height > 1 else { return }
        guard !activeMiniPlayerFileIds.contains(fileId) else { return }
        let targetController = activeWindows[fileId]
            ?? (currentPlayerFileId == fileId ? currentPlayerWindowController : nil)
            ?? activeWindows.first(where: { $0.value.window?.isKeyWindow == true })?.value
            ?? activeWindows.values.first
        guard let controller = targetController, let window = controller.window else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }

        let aspect = videoSize.width / videoSize.height
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let maxAllowedHeight = screenFrame.height * 0.85
        let maxAllowedWidth = screenFrame.width * 0.85

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if aspect < 1.0 {
            // Vertical / Portrait video (e.g. 9:16 or similar vertical short)
            let idealHeight = min(maxAllowedHeight, max(560, screenFrame.height * 0.75))
            var w = (idealHeight * aspect).rounded()
            var h = idealHeight.rounded()
            if w > maxAllowedWidth {
                w = maxAllowedWidth.rounded()
                h = (w / aspect).rounded()
            }
            targetWidth = w
            targetHeight = h
            window.minSize = NSSize(width: 320, height: 480)
        } else {
            // Horizontal / Landscape video (e.g. 16:9)
            var w = min(window.frame.width, maxAllowedWidth)
            if w < 720 {
                w = min(maxAllowedWidth, max(960, screenFrame.width * 0.60)).rounded()
            }
            var h = (w / aspect).rounded()
            if h > maxAllowedHeight {
                h = maxAllowedHeight.rounded()
                w = (h * aspect).rounded()
            }
            if w > maxAllowedWidth {
                w = maxAllowedWidth.rounded()
                h = (w / aspect).rounded()
            }
            targetWidth = w
            targetHeight = h
            window.minSize = NSSize(width: 560, height: 320)
        }

        let currentCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var newX = (currentCenter.x - targetWidth / 2).rounded()
        var newY = (currentCenter.y - targetHeight / 2).rounded()

        if newX < screenFrame.minX { newX = screenFrame.minX }
        if newX + targetWidth > screenFrame.maxX { newX = screenFrame.maxX - targetWidth }
        if newY < screenFrame.minY { newY = screenFrame.minY }
        if newY + targetHeight > screenFrame.maxY { newY = screenFrame.maxY - targetHeight }

        let newFrame = NSRect(x: newX, y: newY, width: targetWidth, height: targetHeight)
        window.setFrame(newFrame, display: true, animate: true)
        window.aspectRatio = NSSize(width: videoSize.width, height: videoSize.height)
    }

    public func setWindowTitleBarButtonsHidden(_ hidden: Bool, for fileId: String? = nil) {
        let targetFileId = fileId ?? currentPlayerFileId
        let window: NSWindow? = {
            if let id = targetFileId, let w = activeWindows[id]?.window {
                return w
            }
            if let keyW = NSApp.keyWindow, activeWindows.values.contains(where: { $0.window === keyW }) {
                return keyW
            }
            return currentPlayerWindowController?.window ?? activeWindows.values.first?.window
        }()
        
        guard let window = window else { return }
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }
    
    public func toggleZoom(for fileId: String) {
        let controller = activeWindows[fileId] ?? currentPlayerWindowController
        guard let controller = controller, let window = controller.window else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        
        if let savedFrame = preZoomFrames.removeValue(forKey: fileId) {
            // Restore previous frame
            window.setFrame(savedFrame, display: true, animate: true)
        } else {
            // Save current frame
            preZoomFrames[fileId] = window.frame
            
            // Calculate aspect ratio (favoring window's aspectRatio property or video aspect)
            let currentAspect: CGFloat = {
                if window.aspectRatio.width > 0 && window.aspectRatio.height > 0 {
                    return window.aspectRatio.width / window.aspectRatio.height
                } else if window.frame.height > 0 {
                    return window.frame.width / window.frame.height
                }
                return 16.0 / 9.0
            }()
            
            var targetWidth = visibleFrame.width
            var targetHeight = (targetWidth / currentAspect).rounded()
            
            if targetHeight > visibleFrame.height {
                targetHeight = visibleFrame.height
                targetWidth = (targetHeight * currentAspect).rounded()
            }
            
            let targetX = (visibleFrame.midX - targetWidth / 2).rounded()
            let targetY = (visibleFrame.midY - targetHeight / 2).rounded()
            
            let targetFrame = NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
            window.setFrame(targetFrame, display: true, animate: true)
        }
    }
    
    public func toggleMiniPlayer(for fileId: String) {
        let windowController = activeWindows[fileId] ?? currentPlayerWindowController
        guard let windowController = windowController,
              let window = windowController.window else { return }
        
        let isAudio = (activeFiles[fileId]?.type == .audio)
        let standardMinSize = isAudio ? NSSize(width: 480, height: 260) : NSSize(width: 560, height: 320)
        
        if activeMiniPlayerFileIds.contains(fileId) {
            // Restore to normal
            activeMiniPlayerFileIds.remove(fileId)
            
            // Restore window level
            let savedLevel = preMiniPlayerLevels.removeValue(forKey: fileId)
            let savedAlwaysOnTop = UserDefaults.standard.bool(forKey: "macPlayerAlwaysOnTop")
            window.level = savedLevel ?? (savedAlwaysOnTop ? .floating : .normal)
            
            window.styleMask.insert([.closable, .miniaturizable, .resizable])
            window.minSize = standardMinSize
            window.appearance = NSAppearance(named: .darkAqua)
            
            if let savedFrame = preMiniPlayerFrames.removeValue(forKey: fileId) {
                let targetScreen = window.screen ?? NSScreen.main
                let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                
                var restoredFrame = savedFrame
                if restoredFrame.width < standardMinSize.width { restoredFrame.size.width = standardMinSize.width }
                if restoredFrame.height < standardMinSize.height { restoredFrame.size.height = standardMinSize.height }
                
                if restoredFrame.maxX > visibleFrame.maxX {
                    restoredFrame.origin.x = visibleFrame.maxX - restoredFrame.width
                }
                if restoredFrame.minX < visibleFrame.minX {
                    restoredFrame.origin.x = visibleFrame.minX
                }
                if restoredFrame.maxY > visibleFrame.maxY {
                    restoredFrame.origin.y = visibleFrame.maxY - restoredFrame.height
                }
                if restoredFrame.minY < visibleFrame.minY {
                    restoredFrame.origin.y = visibleFrame.minY
                }
                
                window.setFrame(restoredFrame, display: true, animate: true)
            } else {
                let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                let defaultWidth: CGFloat = min(1120, max(880, screenFrame.width * 0.62)).rounded()
                let defaultHeight: CGFloat = (defaultWidth / (16.0 / 9.0)).rounded()
                let defaultRect = NSRect(
                    x: (screenFrame.midX - defaultWidth / 2).rounded(),
                    y: (screenFrame.midY - defaultHeight / 2).rounded(),
                    width: defaultWidth,
                    height: defaultHeight
                )
                window.setFrame(defaultRect, display: true, animate: true)
            }
            setWindowTitleBarButtonsHidden(false, for: fileId)
        } else {
            // Enter Mini Player mode
            activeMiniPlayerFileIds.insert(fileId)
            preMiniPlayerFrames[fileId] = window.frame
            preMiniPlayerLevels[fileId] = window.level
            
            window.level = .floating
            window.styleMask.remove([.closable, .miniaturizable, .resizable])
            
            window.minSize = isAudio ? NSSize(width: 280, height: 88) : NSSize(width: 320, height: 180)
            let miniSize = isAudio ? NSSize(width: 320, height: 88) : NSSize(width: 400, height: 225)
            
            let currentFrame = window.frame
            let newX = currentFrame.maxX - miniSize.width
            let newY = currentFrame.maxY - miniSize.height
            window.setFrame(NSRect(x: newX, y: newY, width: miniSize.width, height: miniSize.height), display: true, animate: true)
            setWindowTitleBarButtonsHidden(true, for: fileId)
        }
    }
    
    public func togglePinToTop(for fileId: String) {
        let window = activeWindows[fileId]?.window ?? currentPlayerWindowController?.window
        guard let window = window else { return }
        if activeMiniPlayerFileIds.contains(fileId) {
            let currentSaved = preMiniPlayerLevels[fileId] ?? .normal
            let newLevel: NSWindow.Level = (currentSaved == .floating) ? .normal : .floating
            preMiniPlayerLevels[fileId] = newLevel
            UserDefaults.standard.set(newLevel == .floating, forKey: "macPlayerAlwaysOnTop")
        } else {
            let isCurrentlyFloating = (window.level == .floating)
            let newLevel: NSWindow.Level = isCurrentlyFloating ? .normal : .floating
            window.level = newLevel
            UserDefaults.standard.set(!isCurrentlyFloating, forKey: "macPlayerAlwaysOnTop")
        }
    }
    
    public func isPinnedToTop(for fileId: String) -> Bool {
        if activeMiniPlayerFileIds.contains(fileId) {
            let saved = preMiniPlayerLevels[fileId] ?? (UserDefaults.standard.bool(forKey: "macPlayerAlwaysOnTop") ? .floating : .normal)
            return saved == .floating
        }
        let window = activeWindows[fileId]?.window ?? currentPlayerWindowController?.window
        guard let window = window else { return false }
        return window.level == .floating
    }

    private var originalWindowFrames: [ObjectIdentifier: NSRect] = [:]

    public enum HorizontalAlignment {
        case left, center, right
    }
    
    public enum VerticalAlignment {
        case top, center, bottom
    }

    public enum WindowArrangeStyle {
        case tileHorizontalAspect(vAlign: VerticalAlignment = .center)
        case tileVerticalAspect(hAlign: HorizontalAlignment = .center)
        case tileHorizontalFull
        case tileVerticalFull
        case tileGrid
        case cascade
        case restoreOriginal
    }
    
    public func closeOtherWindows(except fileId: String? = nil) {
        let targetFileId = fileId ?? activeWindows.first(where: { $0.value.window?.isKeyWindow == true })?.key ?? currentPlayerFileId
        let allIds = activeWindows.keys
        for id in allIds {
            if id != targetFileId {
                closePlayer(for: id)
            }
        }
    }
    
    private func aspectFitFrame(
        container: NSRect,
        aspectRatio: CGFloat = 16.0 / 9.0,
        hAlign: HorizontalAlignment = .center,
        vAlign: VerticalAlignment = .center
    ) -> NSRect {
        var w = container.width
        var h = w / aspectRatio
        if h > container.height {
            h = container.height
            w = h * aspectRatio
        }
        
        let x: CGFloat
        switch hAlign {
        case .left:
            x = container.minX
        case .right:
            x = container.maxX - w
        case .center:
            x = container.minX + (container.width - w) / 2.0
        }
        
        let y: CGFloat
        switch vAlign {
        case .top:
            y = container.maxY - h
        case .bottom:
            y = container.minY
        case .center:
            y = container.minY + (container.height - h) / 2.0
        }
        
        return NSRect(x: x, y: y, width: w, height: h)
    }

    public func arrangeWindows(style: WindowArrangeStyle) {
        let windows = activeWindows.values.compactMap { $0.window }.filter { $0.isVisible && !$0.isMiniaturized }
        guard !windows.isEmpty, let screen = NSScreen.main else { return }
        
        // Save initial frames before applying any arrangement if not saved already
        if case .restoreOriginal = style {
            // Restore mode
        } else {
            for window in windows {
                let id = ObjectIdentifier(window)
                if originalWindowFrames[id] == nil {
                    originalWindowFrames[id] = window.frame
                }
            }
        }
        
        let frame = screen.visibleFrame
        let count = CGFloat(windows.count)
        
        switch style {
        case .tileHorizontalAspect(let vAlign):
            let width = frame.width / count
            for (index, window) in windows.enumerated() {
                let slot = NSRect(x: frame.minX + CGFloat(index) * width, y: frame.minY, width: width, height: frame.height)
                let rect = aspectFitFrame(container: slot, vAlign: vAlign)
                window.setFrame(rect, display: true, animate: true)
            }
        case .tileVerticalAspect(let hAlign):
            let height = frame.height / count
            for (index, window) in windows.enumerated() {
                let slot = NSRect(x: frame.minX, y: frame.maxY - CGFloat(index + 1) * height, width: frame.width, height: height)
                let rect = aspectFitFrame(container: slot, hAlign: hAlign)
                window.setFrame(rect, display: true, animate: true)
            }
        case .tileHorizontalFull:
            let width = frame.width / count
            for (index, window) in windows.enumerated() {
                let rect = NSRect(x: frame.minX + CGFloat(index) * width, y: frame.minY, width: width, height: frame.height)
                window.setFrame(rect, display: true, animate: true)
            }
        case .tileVerticalFull:
            let height = frame.height / count
            for (index, window) in windows.enumerated() {
                let rect = NSRect(x: frame.minX, y: frame.maxY - CGFloat(index + 1) * height, width: frame.width, height: height)
                window.setFrame(rect, display: true, animate: true)
            }
        case .tileGrid:
            let cols = Int(ceil(sqrt(count)))
            let rows = Int(ceil(count / CGFloat(cols)))
            let width = frame.width / CGFloat(cols)
            let height = frame.height / CGFloat(rows)
            
            for (index, window) in windows.enumerated() {
                let col = CGFloat(index % cols)
                let row = CGFloat(index / cols)
                let slot = NSRect(
                    x: frame.minX + col * width,
                    y: frame.maxY - (row + 1) * height,
                    width: width,
                    height: height
                )
                let rect = aspectFitFrame(container: slot)
                window.setFrame(rect, display: true, animate: true)
            }
        case .cascade:
            var topLeft = NSPoint(x: frame.minX, y: frame.maxY)
            for window in windows {
                topLeft = window.cascadeTopLeft(from: topLeft)
            }
        case .restoreOriginal:
            for window in windows {
                let id = ObjectIdentifier(window)
                if let savedFrame = originalWindowFrames[id] {
                    window.setFrame(savedFrame, display: true, animate: true)
                    originalWindowFrames.removeValue(forKey: id)
                }
            }
        }
        
        // Ensure all active player windows are brought to front so none remain behind
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for window in windows {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.orderFrontRegardless()
            }
            self.currentPlayerWindowController?.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    public func registerMainWindow(_ window: NSWindow) {
        if let existing = self.mainWindow, existing !== window {
            let playerWindows = Set(activeWindows.values.compactMap { $0.window })
            if !playerWindows.contains(existing) && NSApp.windows.contains(existing) {
                // Duplicate main window spawned by SwiftUI WindowGroup! Close it immediately
                DispatchQueue.main.async {
                    window.close()
                    if !self.isOpeningExternalFile {
                        existing.alphaValue = 1.0
                        existing.makeKeyAndOrderFront(nil)
                    }
                }
                return
            }
        }
        
        self.mainWindow = window
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        
        let delegate = MacMainWindowDelegate()
        self.mainWindowDelegate = delegate
        window.delegate = delegate
        
        if isOpeningExternalFile {
            window.orderOut(nil)
            
            // Ensure window stays ordered out even if SwiftUI's initial scene presentation attempts to order it front
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isOpeningExternalFile else { return }
                window.orderOut(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self = self, self.isOpeningExternalFile else { return }
                window.orderOut(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self, self.isOpeningExternalFile else { return }
                window.orderOut(nil)
            }
        }
    }

    public func hideMainWindow() {
        if let window = self.mainWindow {
            window.orderOut(nil)
        }
        
        let playerWindows = Set(activeWindows.values.compactMap { $0.window })
        for window in NSApp.windows where !playerWindows.contains(window) && !(window is NSPanel) {
            window.orderOut(nil)
        }
    }
    
    @discardableResult
    public func showMainWindow() -> Bool {
        isOpeningExternalFile = false
        
        let playerWindows = Set(activeWindows.values.compactMap { $0.window })
        let mainCandidateWindows = NSApp.windows.filter {
            !playerWindows.contains($0) && !($0 is NSPanel) && $0.sheetParent == nil
        }
        
        // If there are multiple main windows, close duplicates and keep only the first one
        if mainCandidateWindows.count > 1 {
            for duplicate in mainCandidateWindows.dropFirst() {
                duplicate.close()
            }
        }
        
        if let targetWindow = self.mainWindow ?? mainCandidateWindows.first {
            self.mainWindow = targetWindow
            targetWindow.alphaValue = 1.0
            if targetWindow.isMiniaturized {
                targetWindow.deminiaturize(nil)
            }
            if let attached = targetWindow.attachedSheet {
                attached.makeKeyAndOrderFront(nil)
            } else {
                targetWindow.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    public func openLocalFileURL(_ url: URL, hideMainWindow: Bool = false) {
        if hideMainWindow {
            self.isOpeningExternalFile = true
            self.hideMainWindow()
        }
        _ = MacLocalFolderBookmarkService.shared.ensureAccess(for: url)
        let type = VideoFile.FileType.determineType(from: url)
        guard type == .video || type == .audio else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
        let videoFile = VideoFile(name: url.lastPathComponent, url: url, type: type, size: size, date: date, isRemote: false)
        self.openPlayer(for: videoFile)
        
        if hideMainWindow {
            self.hideMainWindow()
        }
    }

    public func openNetworkURL(_ url: URL, hideMainWindow: Bool = false) {
        if hideMainWindow {
            self.isOpeningExternalFile = true
            self.hideMainWindow()
        }
        let type = VideoFile.FileType.determineType(from: url)
        let resolvedType: VideoFile.FileType = (type == .audio) ? .audio : .video
        let name = url.lastPathComponent.isEmpty ? (url.host ?? url.absoluteString) : url.lastPathComponent
        let videoFile = VideoFile(
            name: name,
            url: url,
            type: resolvedType,
            size: 0,
            date: Date(),
            isRemote: true
        )
        self.openPlayer(for: videoFile)
        
        if hideMainWindow {
            self.hideMainWindow()
        }
    }
    
    @discardableResult
    public func openNetworkURLString(_ urlString: String, hideMainWindow: Bool = false) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return false
        }
        openNetworkURL(url, hideMainWindow: hideMainWindow)
        return true
    }
}

public struct MacMainWindowAccessor: NSViewRepresentable {
    public init() {}
    
    public func makeNSView(context: Context) -> NSView {
        let view = MacMainWindowTrackingView()
        return view
    }
    
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

private class MacMainWindowTrackingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            MacPlayerWindowManager.shared.registerMainWindow(window)
        }
    }
}

private class MacMainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
#endif
