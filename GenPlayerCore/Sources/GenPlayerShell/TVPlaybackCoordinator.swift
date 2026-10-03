#if os(tvOS)
import Foundation
import SwiftUI
import Combine
import CoreText
import GenPlayerCore
import GenPlayerFontSupport

@MainActor
public final class TVPlaybackCoordinator: ObservableObject {
    public struct Request: Identifiable {
        public let id = UUID()
        public let file: VideoFile
        public let playlist: [VideoFile]?

        public init(file: VideoFile, playlist: [VideoFile]? = nil) {
            self.file = file
            self.playlist = playlist
        }
    }

    public static let shared = TVPlaybackCoordinator()

    nonisolated public static func setupFontInterceptor() {
        if let fontURL = Bundle.main.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf")
            ?? Bundle.module.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf") {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
            #if DEBUG
            if let error {
                print("[FontSupport] Error registering font: \(error.takeUnretainedValue())")
            } else {
                print("[FontSupport] Successfully registered CJK font at startup.")
            }
            #endif
        }
        GenPlayerInstallCJKFontInterceptor()
    }

    @Published public var activeRequest: Request?
    /// An event must not invalidate the presenting root while it is being handled.
    public let exitCommands = PassthroughSubject<String, Never>()

    public func requestExitCommand(source: String = "unspecified") {
        guard activeRequest != nil else { return }
        traceExit("request source=\(source)")
        exitCommands.send(source)
    }
    private var suppressExitCommandsUntil: Date?

    private init() {}

    public func play(file: VideoFile, playlist: [VideoFile]? = nil) {
        suppressExitCommandsUntil = nil
        activeRequest = Request(file: file, playlist: playlist)
        g_GenPlayerCJKFontInterceptorEnabled = true
    }

    public func dismiss(suppressExitCommandsFor interval: TimeInterval = 0) {
        traceExit("clear-request", includeStack: true)
        if interval > 0 {
            suppressExitCommandsUntil = Date().addingTimeInterval(interval)
        }
        activeRequest = nil
        g_GenPlayerCJKFontInterceptorEnabled = false
    }

    /// Debug-only control-flow diagnostics. Never include media URLs or credentials.
    public func traceExit(_ event: String, includeStack: Bool = false) {
        #if DEBUG
        NSLog("[TVPlaybackExit] request=%@ %@", activeRequest?.id.uuidString ?? "none", event)
        if includeStack {
            NSLog("[TVPlaybackExit] stack %@", Thread.callStackSymbols.prefix(12).joined(separator: " | "))
        }
        #endif
    }

    public func shouldSuppressExitCommands() -> Bool {
        TVPlaybackBackPolicy.suppressBackgroundNavigation(
            playbackActive: activeRequest != nil, until: suppressExitCommandsUntil, now: Date())
    }
}
#endif

