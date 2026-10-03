import Testing
@testable import GenPlayer

struct PlaybackStallDetectorTests {
    private func sample(_ time: Int32 = 0, video: Int32 = 0, audio: Int32 = 0) -> PlaybackStallDetector.Sample {
        .init(timeMilliseconds: time, displayedPictures: video, playedAudioBuffers: audio)
    }

    @Test func transientBufferingDoesNotInterruptAdvancingPlayback() {
        var detector = PlaybackStallDetector()
        #expect(detector.isStalled(sample: sample(1000), now: 0) == false)
        #expect(detector.isStalled(sample: sample(1000), now: 0.1) == false)
        #expect(detector.isStalled(sample: sample(1200), now: 0.2) == false)
        #expect(detector.isStalled(sample: sample(1200), now: 0.3) == false)
        #expect(detector.isStalled(sample: sample(1500), now: 0.5) == false)
    }

    @Test func delayedDelegateCallbacksDoNotCountAsAStall() {
        var detector = PlaybackStallDetector()
        #expect(detector.isStalled(sample: sample(1000), now: 0) == false)
        // The next observation may arrive late, but the engine clock kept advancing.
        #expect(detector.isStalled(sample: sample(6000), now: 5) == false)
    }

    @Test func liveVideoOutputWorksWithoutAnAdvancingClock() {
        var detector = PlaybackStallDetector()
        #expect(detector.isStalled(sample: sample(video: 100), now: 0) == false)
        #expect(detector.isStalled(sample: sample(video: 200), now: 4) == false)
    }

    @Test func audioOutputWorksWithoutVideoFrames() {
        var detector = PlaybackStallDetector()
        #expect(detector.isStalled(sample: sample(audio: 100), now: 0) == false)
        #expect(detector.isStalled(sample: sample(audio: 200), now: 4) == false)
    }

    @Test func repeatedUnchangedNotificationsStillRevealARealStall() {
        var detector = PlaybackStallDetector()
        let frozen = sample(1000, video: 24, audio: 48)
        #expect(detector.isStalled(sample: frozen, now: 0) == false)
        #expect(detector.isStalled(sample: frozen, now: 1) == false)
        #expect(detector.isStalled(sample: frozen, now: 1.49) == false)
        #expect(detector.isStalled(sample: frozen, now: 1.5) == true)
        #expect(detector.isStalled(sample: frozen, now: 4) == true)
        #expect(detector.isStalled(sample: sample(1200, video: 28, audio: 52), now: 4.1) == false)
    }

    @Test func pauseOrNewSessionResetsTheObservationWindow() {
        var detector = PlaybackStallDetector()
        _ = detector.isStalled(sample: sample(1000), now: 0)
        #expect(detector.isStalled(sample: sample(1000), now: 2) == true)
        detector.reset()
        #expect(detector.isStalled(sample: sample(1000), now: 100) == false)
        #expect(detector.isStalled(sample: sample(1000), now: 101) == false)
    }

    @Test func seekTargetAloneDoesNotCountAsResumedPlayback() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(1000), now: 0)
        #expect(detector.isStalled(sample: sample(60000), now: 0.1) == false)
        #expect(detector.isAwaitingSeekPlayback)
        #expect(detector.isStalled(sample: sample(60000), now: 0.3) == true)
        #expect(detector.isStalled(sample: sample(60000), now: 2) == true)
        #expect(detector.isStalled(sample: sample(60200), now: 2.1) == false)
        #expect(!detector.isAwaitingSeekPlayback)
    }

    @Test func backwardSeekWaitsForPlaybackBeyondItsTarget() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(60000), now: 0)
        #expect(detector.isStalled(sample: sample(10000), now: 0.1) == false)
        #expect(detector.isStalled(sample: sample(10000), now: 0.4) == true)
        #expect(detector.isStalled(sample: sample(10200), now: 0.5) == false)
        #expect(!detector.isAwaitingSeekPlayback)
    }

    @Test func seekWithoutAnyClockUpdateStillShowsLoading() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(1000), now: 0)
        #expect(detector.isStalled(sample: sample(1000), now: 0.29) == false)
        #expect(detector.isStalled(sample: sample(1000), now: 0.3) == true)
        #expect(detector.isAwaitingSeekPlayback)
    }

    @Test func fastSeekDoesNotFlashLoading() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(1000), now: 0)
        #expect(detector.isStalled(sample: sample(60000), now: 0.1) == false)
        #expect(detector.isStalled(sample: sample(60100), now: 0.2) == false)
        #expect(!detector.isAwaitingSeekPlayback)
        #expect(detector.isStalled(sample: sample(60200), now: 0.3) == false)
    }

    @Test func videoOutputClearsSeekLoadingWithoutAClockTick() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(1000, video: 100), now: 0)
        #expect(detector.isStalled(sample: sample(1000, video: 100), now: 0.5) == true)
        #expect(detector.isStalled(sample: sample(1000, video: 101), now: 0.6) == false)
        #expect(!detector.isAwaitingSeekPlayback)
    }

    @Test func audioOutputClearsSeekLoadingWithoutVideo() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(1000, audio: 100), now: 0)
        #expect(detector.isStalled(sample: sample(1000, audio: 100), now: 0.5) == true)
        #expect(detector.isStalled(sample: sample(1000, audio: 101), now: 0.6) == false)
        #expect(!detector.isAwaitingSeekPlayback)
    }

    @Test func anotherSeekDiscardsThePreviousTargetAndWaitWindow() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(1000), now: 0)
        #expect(detector.isStalled(sample: sample(60000), now: 0.4) == true)
        detector.beginSeek(sample: sample(60000), now: 1)
        #expect(detector.isStalled(sample: sample(120000), now: 1.1) == false)
        #expect(detector.isAwaitingSeekPlayback)
        #expect(detector.isStalled(sample: sample(120000), now: 1.4) == true)
        #expect(detector.isStalled(sample: sample(120100), now: 1.5) == false)
    }

    @Test func pauseOrNewSessionCancelsPendingSeekLoading() {
        var detector = PlaybackStallDetector()
        detector.beginSeek(sample: sample(1000), now: 0)
        #expect(detector.isStalled(sample: sample(60000), now: 0.4) == true)
        detector.reset()
        #expect(!detector.isAwaitingSeekPlayback)
        #expect(detector.isStalled(sample: sample(60000), now: 100) == false)
        #expect(detector.isStalled(sample: sample(60000), now: 100.5) == false)
    }
}
