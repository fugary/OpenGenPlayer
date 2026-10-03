#!/usr/bin/env python3
"""Run the production back router with in-memory navigation substitutes. No GUI."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'GenPlayerCore/Sources/GenPlayerShell/TVBrowsingNavigation.swift').read_text()
router = source[source.index('final class TVBrowsingNavigation:'):source.index('private struct TVBrowsingNavigationKey:')]
stubs = r'''
import Foundation
protocol ObservableObject {}
final class UINavigationController {
    var viewControllers: [Int]
    var transitionCoordinator: Int?
    var pops = 0
    init(depth: Int) { viewControllers = Array(0..<depth) }
    func popViewController(animated: Bool) { viewControllers.removeLast(); pops += 1 }
    func popToRootViewController(animated: Bool) { viewControllers = Array(viewControllers.prefix(1)); pops += 1 }
}
'''
tests = r'''
@main enum Checks {
    static func tick() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    @MainActor static func main() async {
        var checks = 0, exits = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        let browser = TVBrowsingNavigation()
        browser.onExit = { exits += 1 }
        // No active controller must never be interpreted as a server root.
        browser.back(); check(exits == 0); await tick()
        let stack = UINavigationController(depth: 3)
        let backgroundStack = UINavigationController(depth: 7)
        browser.controller = stack
        browser.back(); browser.back()
        check(stack.viewControllers.count == 2 && stack.pops == 1 && exits == 0)
        check(backgroundStack.viewControllers.count == 7)
        await tick()
        browser.back(); check(stack.viewControllers.count == 1 && exits == 0)
        await tick()
        browser.back(); browser.back(); check(exits == 1)
        await tick()
        // Repeated Menu while the native pop is animating must be consumed.
        stack.transitionCoordinator = 1
        browser.back(); check(exits == 1 && stack.pops == 2)
        check(browser.pop(toRoot: true))
        await tick(); stack.transitionCoordinator = nil
        var parentMoves = 0
        browser.back(custom: { parentMoves += 1; return true })
        check(parentMoves == 1 && exits == 1)
        await tick()
        stack.viewControllers = [0, 1, 2, 3]
        browser.back(custom: { browser.pop() })
        check(stack.viewControllers.count == 3 && stack.pops == 3 && exits == 1)
        await tick()
        check(browser.pop(toRoot: true) && stack.viewControllers == [0])
        check(!browser.pop() && exits == 1)
        stack.viewControllers = []
        browser.back(); check(exits == 1)
        await tick()
        browser.controller = nil
        browser.back(); check(exits == 1)
        print("PASS: \(checks) production browsing-back checks (no app or simulator)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='genplayer-tv-browsing-') as directory:
    path = Path(directory)
    (path / 'check.swift').write_text(stubs + router + tests)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'),
                    str(path / 'check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
