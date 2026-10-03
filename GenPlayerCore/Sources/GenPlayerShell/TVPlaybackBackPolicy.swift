import Foundation

/// One Back command changes exactly one layer. Also used by covered navigation
/// pages so they cannot remove the presenter while a playback request is active.
enum TVPlaybackBackPolicy {
    enum Action: Equatable {
        case nativeMenu, positionAdjustment, scrubbing, playlist, submenu, panel, chrome, exit
    }

    static func action(nativeMenu: Bool, positionAdjustment: Bool, scrubbing: Bool,
                       playlist: Bool, submenu: Bool, panel: Bool, chrome: Bool) -> Action {
        if nativeMenu { return .nativeMenu }
        if positionAdjustment { return .positionAdjustment }
        if scrubbing { return .scrubbing }
        if playlist { return .playlist }
        if submenu { return .submenu }
        if panel { return .panel }
        if chrome { return .chrome }
        return .exit
    }

    static func suppressBackgroundNavigation(playbackActive: Bool, until: Date?, now: Date) -> Bool {
        playbackActive || until.map { now < $0 } == true
    }
}
