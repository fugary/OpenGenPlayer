#!/usr/bin/env python3
"""Run production iOS lifecycle methods with inert dependencies; no app or media."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else (
    root / 'GenPlayer/Source/Services/VLCPlaybackService.swift').read_text()


def method(name):
    match = re.search(r'^    (?:@objc )?private func ' + name + r'\(', source, re.M)
    if not match:
        if name == 'updateMPVVideoForApplicationState':
            return ''  # Allow the same regression checks against the pre-fix source.
        raise ValueError('Missing production method: ' + name)
    end = source.index('\n    }', match.start()) + len('\n    }')
    return source[match.start():end].replace('@objc ', '').replace('private func', 'func', 1)


methods = '\n'.join(method(name) for name in [
    'updateMPVVideoForApplicationState', 'handleWillResignActive',
    'handleDidEnterBackground', 'handleDidBecomeActive'])
startup = source[source.index('let speed = sessionPlaybackRate ?? Float(audioOnly'):]
video_option = re.search(r'"vid": (.*?),\n', startup).group(1)
swift = r'''
import Foundation
enum ItemType { case video, audio }
struct Item { var type: ItemType = .video }
enum Status { case idle, playing, paused, ended }
struct State { var currentItem: Item? = Item(); var status: Status = .playing }
struct File { let id: String; let name: String }
enum AppState { case active, inactive, background }
final class UIApplication {
    static let shared = UIApplication()
    var applicationState: AppState = .active
}
final class AppSettings {
    static let shared = AppSettings()
    var shouldPlayInBackground = false
}
final class Engine {
    let usesPixelBufferOutput: Bool
    var writes: [String] = []
    init(pixel: Bool) { usesPixelBufferOutput = pixel }
    func set(_ key: String, _ value: String) { writes.append("\(key)=\(value)") }
}
struct PiP { var isPreparingOrActive = true }
final class Intelligence {
    var background = false
    func setBackground(_ value: Bool) { background = value }
}
final class Service {
    var mpvEngine: Engine?
    var state = State()
    var isVideoPiPActive = false
    var videoPiPController: PiP?
    var subtitleIntelligence = Intelligence()
    var pendingActivationReconciliationWorkItem: DispatchWorkItem?
    var pendingMetadataWorkItem: DispatchWorkItem?
    var pictureInPictureSeekResumeGraceDeadline: Double = .zero
    var hasTerminalPlaybackFailure = false
    var isPlaybackSuspendedForBackground = false
    var pendingPictureInPictureRestoreFile: File?
    var requestedVideoPlayerRestoreFile: File?
    var pauses = 0
    var deactivations = 0
    var clearedGestures = 0
    var reattachments = 0
    var reconciliations = 0
    func resolvedPlaybackItemType(for item: Item) -> ItemType { item.type }
    func clearAllInteractiveVideoGestureActivity() { clearedGestures += 1 }
    func invalidatePendingPlaybackControls() {}
    func deactivateAudioSessionIfPossible(reason: String, force: Bool) { deactivations += 1 }
    func cancelPendingPlaybackFailure() {}
    func stopStartupWatchdog() {}
    func pausePlaybackSmoothly(clearNowPlayingImmediately: Bool, deactivateAudioSessionAfterPause: Bool) {
        pauses += 1; state.status = .paused
    }
    func reattachPlayerViewIfNeeded() { reattachments += 1 }
    func schedulePlaybackReconciliationAfterActivation() { reconciliations += 1 }
__METHODS__
}
var checks = 0
var failures = 0
func check(_ passed: Bool, _ scenario: String) {
    checks += 1
    if !passed { failures += 1; print("FAIL: \(scenario)") }
}
// Run both UIKit background notifications, then foreground, in their real order.
for backgroundEnabled in [false, true] {
    AppSettings.shared.shouldPlayInBackground = backgroundEnabled
    for activePiP in [false, true] {
        let service = Service()
        service.mpvEngine = Engine(pixel: true)
        service.isVideoPiPActive = activePiP
        service.videoPiPController = PiP()
        service.handleWillResignActive()
        service.handleDidEnterBackground()
        check(service.mpvEngine!.writes.isEmpty, "PiP active/starting retains video in background")
        check(service.pauses == 0 && !service.isPlaybackSuspendedForBackground, "PiP active/starting retains playback")
        check(service.subtitleIntelligence.background && service.clearedGestures == 1, "PiP still suspends intelligence and clears gestures")
        service.handleDidBecomeActive()
        check(service.mpvEngine!.writes.isEmpty && service.pauses == 0, "PiP foreground does not reselect video")
        check(!service.subtitleIntelligence.background, "foreground resumes intelligence")
    }
    for type: ItemType in [.video, .audio] {
        let service = Service()
        service.mpvEngine = Engine(pixel: false)
        service.state.currentItem = Item(type: type)
        service.handleWillResignActive()
        service.handleDidEnterBackground()
        check(service.mpvEngine!.writes == ["vid=no", "vid=no"], "ordinary output stops drawing in background")
        check(service.pauses == (backgroundEnabled ? 0 : 1), "ordinary playback follows background preference")
        service.handleDidBecomeActive()
        check(service.mpvEngine!.writes.last == (type == .audio ? "vid=no" : "vid=auto"), "foreground restores ordinary video only")
        check(service.state.status == (backgroundEnabled ? .playing : .paused), "foreground does not auto-resume")
    }
}
AppSettings.shared.shouldPlayInBackground = false
let paused = Service()
paused.mpvEngine = Engine(pixel: true)
paused.state.status = .paused
paused.videoPiPController = PiP()
paused.handleWillResignActive(); paused.handleDidEnterBackground(); paused.handleDidBecomeActive()
check(paused.state.status == .paused && paused.mpvEngine!.writes.isEmpty, "paused PiP stays paused without discarding video")
let inactiveOutput = Service()
inactiveOutput.mpvEngine = Engine(pixel: true)
inactiveOutput.handleDidEnterBackground()
check(inactiveOutput.pauses == 1, "offscreen output without PiP still follows background preference")
for terminalStatus: Status in [.playing, .ended] {
    let terminal = Service()
    terminal.mpvEngine = Engine(pixel: true)
    terminal.videoPiPController = PiP()
    terminal.state.status = terminalStatus
    terminal.hasTerminalPlaybackFailure = terminalStatus == .playing
    terminal.handleDidEnterBackground()
    check(terminal.deactivations == 1 && terminal.pauses == 0, "failed/ended PiP preparation retains terminal background cleanup")
}
let vlc = Service()
vlc.isVideoPiPActive = true
vlc.handleWillResignActive(); vlc.handleDidEnterBackground(); vlc.handleDidBecomeActive()
check(vlc.pauses == 0 && vlc.reattachments == 1 && vlc.reconciliations == 1, "VLC PiP retains its lifecycle path")
// A PiP rebuild finishing after resign-active must start with video enabled.
for appState: AppState in [.active, .inactive, .background] {
    UIApplication.shared.applicationState = appState
    for audioOnly in [false, true] {
        for hasPixelOutput in [false, true] {
            let pixelOutput: Int? = hasPixelOutput ? 1 : nil
            let value = __VIDEO_OPTION__
            let expected = audioOnly ? "no" : (hasPixelOutput || appState == .active ? "auto" : "no")
            check(value == expected, "startup video option respects offscreen output, app state and audio-only")
        }
    }
}
if failures > 0 { print("\(failures) of \(checks) lifecycle checks failed"); exit(1) }
print("PASS: \(checks) production iOS mpv lifecycle checks (no app, simulator or media opened)")
'''.replace('__METHODS__', methods).replace('__VIDEO_OPTION__', video_option)

with tempfile.TemporaryDirectory(prefix='genplayer-mpv-lifecycle-') as temp:
    folder = Path(temp)
    code, binary = folder / 'main.swift', folder / 'check'
    code.write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'cache'),
                    str(code), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
