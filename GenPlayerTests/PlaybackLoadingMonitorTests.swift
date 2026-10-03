import Testing
@testable import GenPlayer

struct PlaybackLoadingMonitorTests {
    @Test func slowStartupDoesNotBecomeAFailureAtFifteenSeconds() {
        var monitor = PlaybackLoadingMonitor(isRemote: true, now: 0)
        #expect(monitor.update(now: 14.9, progressValue: 0) == .loading)
        #expect(monitor.update(now: 15, progressValue: 0) == .slow)
        #expect(monitor.update(now: 29.9, progressValue: 0) == .slow)
        #expect(monitor.update(now: 30, progressValue: 0) == .waitingForChoice)
    }

    @Test func incomingDataExtendsInactivityWindowButDoesNotWaitForever() {
        var monitor = PlaybackLoadingMonitor(isRemote: true, now: 0)
        for second in 1...59 {
            #expect(monitor.update(now: Double(second), progressValue: Int64(second * 100)) != .waitingForChoice)
        }
        #expect(monitor.update(now: 60, progressValue: 6000) == .waitingForChoice)
    }

    @Test func frozenBufferingCountsFromTheLastActualProgress() {
        var monitor = PlaybackLoadingMonitor(isRemote: true, now: 0)
        _ = monitor.update(now: 20, progressValue: 100)
        #expect(monitor.update(now: 49.9, progressValue: 100) == .slow)
        #expect(monitor.update(now: 50, progressValue: 100) == .waitingForChoice)
    }

    @Test func continueWaitingStartsANewObservationWindow() {
        var monitor = PlaybackLoadingMonitor(isRemote: true, now: 0)
        #expect(monitor.update(now: 30, progressValue: 0) == .waitingForChoice)
        // Late packets must not make the buttons disappear before playback resumes.
        #expect(monitor.update(now: 31, progressValue: 100) == .waitingForChoice)
        monitor.continueWaiting(now: 40)
        #expect(monitor.update(now: 40, progressValue: 100) == .loading)
        #expect(monitor.update(now: 55, progressValue: 100) == .slow)
        #expect(monitor.update(now: 70, progressValue: 100) == .waitingForChoice)
    }

    @Test func localIndexingOffersHelpWithoutDeclaringCorruption() {
        var monitor = PlaybackLoadingMonitor(isRemote: false, now: 100)
        #expect(monitor.update(now: 105.9, progressValue: 0) == .loading)
        #expect(monitor.update(now: 106, progressValue: 0) == .slow)
        #expect(monitor.update(now: 115, progressValue: 0) == .waitingForChoice)
    }

    @Test func newBufferingEpisodeDoesNotReuseThePreviousWait() {
        var monitor = PlaybackLoadingMonitor(isRemote: true, now: 0)
        _ = monitor.update(now: 30, progressValue: 0)
        monitor = PlaybackLoadingMonitor(isRemote: true, now: 100, progressValue: 2000)
        #expect(monitor.update(now: 101, progressValue: 2000) == .loading)
        #expect(monitor.update(now: 130, progressValue: 2000) == .waitingForChoice)
    }
}
