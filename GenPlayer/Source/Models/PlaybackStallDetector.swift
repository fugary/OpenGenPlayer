import Foundation

/// Inspect playback output, rather than the frequency of VLC delegate notifications.
struct PlaybackStallDetector {
    struct Sample: Equatable {
        let timeMilliseconds: Int32
        let displayedPictures: Int32
        let playedAudioBuffers: Int32
    }

    private var lastSample: Sample?
    private var lastProgressAt: TimeInterval?
    private var seekStartedAt: TimeInterval?
    private var seekClockAnchor: Int32?

    var isAwaitingSeekPlayback: Bool { seekStartedAt != nil }

    mutating func reset() {
        lastSample = nil
        lastProgressAt = nil
        seekStartedAt = nil
        seekClockAnchor = nil
    }

    mutating func beginSeek(sample: Sample, now: TimeInterval) {
        lastSample = sample
        lastProgressAt = now
        seekStartedAt = now
        seekClockAnchor = nil
    }

    mutating func isStalled(sample: Sample, now: TimeInterval) -> Bool {
        if let seekStartedAt, let previous = lastSample {
            let outputAdvanced = sample.displayedPictures > previous.displayedPictures
                || sample.playedAudioBuffers > previous.playedAudioBuffers
            // The first clock change may be the optimistic seek target. Only a later
            // forward tick (or actual output) proves that playback has resumed.
            let clockAdvanced = seekClockAnchor.map { sample.timeMilliseconds > $0 } ?? false
            if outputAdvanced || clockAdvanced {
                self.seekStartedAt = nil
                seekClockAnchor = nil
                lastSample = sample
                lastProgressAt = now
                return false
            }
            if sample.timeMilliseconds != previous.timeMilliseconds {
                seekClockAnchor = sample.timeMilliseconds
            }
            lastSample = sample
            return now - seekStartedAt >= 0.3
        }
        if sample != lastSample {
            lastSample = sample
            lastProgressAt = now
        }
        guard let lastProgressAt else { return false }
        return now - lastProgressAt >= 1.5
    }
}
