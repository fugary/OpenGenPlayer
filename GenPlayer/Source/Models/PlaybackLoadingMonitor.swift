import Foundation

/// Elapsed time is a reason to offer help, not evidence that playback has failed.
struct PlaybackLoadingMonitor {
    enum Phase: Equatable {
        case loading, slow, waitingForChoice
    }

    private let slowDelay: TimeInterval
    private let inactivityLimit: TimeInterval
    private let waitingLimit: TimeInterval
    private var startedAt: TimeInterval
    private var lastProgressAt: TimeInterval
    private var progressValue: Int64
    private(set) var phase: Phase = .loading

    init(isRemote: Bool, now: TimeInterval, progressValue: Int64 = 0) {
        slowDelay = isRemote ? 15 : 6
        inactivityLimit = isRemote ? 30 : 15
        waitingLimit = isRemote ? 60 : 30
        startedAt = now
        lastProgressAt = now
        self.progressValue = progressValue
    }

    mutating func update(now: TimeInterval, progressValue: Int64) -> Phase {
        // Counters can reset/wrap when VLC changes input. A changed counter is activity;
        // a repeated opening/buffering notification by itself is not.
        if progressValue != self.progressValue {
            lastProgressAt = now
            self.progressValue = progressValue
        }
        if phase == .waitingForChoice { return phase }
        if now - lastProgressAt >= inactivityLimit || now - startedAt >= waitingLimit {
            phase = .waitingForChoice
        } else if now - startedAt >= slowDelay {
            phase = .slow
        }
        return phase
    }

    mutating func continueWaiting(now: TimeInterval) {
        startedAt = now
        lastProgressAt = now
        phase = .loading
    }
}
