#!/usr/bin/env python3
"""Execute the production window coordinator with in-memory UIKit substitutes.
No app, simulator, real window, or media is opened.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'GenPlayer_tvOS/Source/App/GenPlayerTVApp.swift').read_text()
start = source.index('    final class Coordinator {', source.index('private struct TVPlaybackWindowPresenter'))
end = source.index('\n}\n\nprivate final class TVPlaybackHostingController', start)
coordinator = source[start:end]
stubs = r'''
import Foundation
struct Color { static let black = Color() }
enum ColorScheme { case dark, light }
struct EnvironmentValues { var locale = Locale.current }
struct TVPlaybackPresentationView {
    let request: TVPlaybackCoordinator.Request
    func id(_ id: UUID) -> Self { self }
    func ignoresSafeArea() -> Self { self }
    func environment<T>(_ path: KeyPath<EnvironmentValues, T>, _ value: T) -> Self { self }
    func preferredColorScheme(_ value: ColorScheme?) -> Self { self }
}
struct AnyView { let id: UUID; init(_ view: TVPlaybackPresentationView) { id = view.request.id } }
final class View { var window: UIWindow?; var backgroundColor: Color? }
class UIViewController { let view = View() }
final class TVPlaybackHostingController: UIViewController {
    var rootView: AnyView
    var dismissCount = 0
    init(rootView: AnyView) { self.rootView = rootView }
    func dismiss(animated: Bool) { dismissCount += 1 }
}
final class Scene { var windows: [UIWindow] = [] }
final class UIWindow {
    struct Level { let rawValue: Double }
    var windowLevel = Level(rawValue: 0)
    var windowScene: Scene?
    var backgroundColor: Color?
    var rootViewController: TVPlaybackHostingController?
    var isHidden = false { didSet { if isHidden { isKeyWindow = false } } }
    var isKeyWindow = false
    init(windowScene: Scene) { self.windowScene = windowScene; windowScene.windows.append(self) }
    func makeKey() { windowScene?.windows.forEach { $0.isKeyWindow = false }; isKeyWindow = true }
    func makeKeyAndVisible() { isHidden = false; makeKey() }
}
enum TVAppLanguageResolver { static func resolvedLanguage(for value: String) -> String { value } }
final class TVPlaybackCoordinator {
    struct Request { let id = UUID() }
    static let shared = TVPlaybackCoordinator()
    var activeRequest: Request?
    func traceExit(_ event: String, includeStack: Bool = false) {}
}
'''
tests = r'''
@main enum Check {
    static func main() async {
        var count = 0
        func check(_ condition: Bool) { precondition(condition); count += 1 }
        let scene = Scene(), anchor = UIViewController()
        let library = UIWindow(windowScene: scene)
        library.makeKeyAndVisible(); anchor.view.window = library
        let owner = Coordinator(), first = TVPlaybackCoordinator.Request()
        TVPlaybackCoordinator.shared.activeRequest = first
        owner.update(request: first, userTheme: "Dark", appLanguage: "en", presenter: anchor)
        let player = scene.windows.last!, host = scene.windows.last!.rootViewController!
        check(scene.windows.count == 2 && player.isKeyWindow && !library.isKeyWindow)
        check(player.windowLevel.rawValue > library.windowLevel.rawValue)
        check(host.rootView.id == first.id)
        owner.update(request: first, userTheme: "Light", appLanguage: "zh-Hans", presenter: anchor)
        check(scene.windows.count == 2 && player.rootViewController === host)
        let next = TVPlaybackCoordinator.Request()
        TVPlaybackCoordinator.shared.activeRequest = next
        owner.update(request: next, userTheme: "Dark", appLanguage: "en", presenter: anchor)
        check(scene.windows.count == 2 && host.rootView.id == next.id)
        TVPlaybackCoordinator.shared.activeRequest = nil
        owner.update(request: nil, userTheme: "Dark", appLanguage: "en", presenter: anchor)
        check(player.isHidden && player.rootViewController == nil && library.isKeyWindow)
        check(host.dismissCount == 1)
        owner.closePlaybackWindow()
        check(host.dismissCount == 1)
        owner.update(request: next, userTheme: "Dark", appLanguage: "en", presenter: anchor)
        let reopened = scene.windows.last!
        check(reopened !== player && reopened.isKeyWindow)
        let another = UIWindow(windowScene: scene); another.makeKeyAndVisible()
        owner.closePlaybackWindow()
        check(another.isKeyWindow && !library.isKeyWindow)

        // A queued open must not recreate playback after cancellation/dismantling.
        let late = Coordinator(), unattached = UIViewController()
        TVPlaybackCoordinator.shared.activeRequest = first
        late.update(request: first, userTheme: "Dark", appLanguage: "en", presenter: unattached)
        late.closePlaybackWindow()
        unattached.view.window = library
        let before = scene.windows.count
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        check(scene.windows.count == before)
        print("PASS: \(count) production playback-window lifecycle checks (in-memory window substitutes; no GUI)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='genplayer-tv-window-') as directory:
    path = Path(directory)
    (path / 'check.swift').write_text(stubs + coordinator + tests)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(path/'cache'), str(path/'check.swift'), '-o', str(path/'check')], check=True)
    subprocess.run([str(path/'check')], check=True)
