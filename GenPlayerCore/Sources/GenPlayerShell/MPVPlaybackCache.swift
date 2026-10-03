import Foundation

/// Seconds on the media timeline; gaps are intentional, never inferred from byte counts.
public struct MPVBufferedRange: Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }

    /// Only count the contiguous seekable range containing the playhead, never future islands.
    public static func aheadSeconds(_ ranges: [Self], time: Double, duration: Double) -> Double? {
        guard time.isFinite, time >= 0, duration.isFinite, duration > 0 else { return nil }
        let valid = normalized(ranges, duration: duration)
        guard !valid.isEmpty else { return nil }
        return valid.first(where: { $0.start <= time && time <= $0.end }).map { max(0, $0.end - time) } ?? 0
    }

    public static func normalized(_ ranges: [Self], duration: Double) -> [Self] {
        guard duration.isFinite, duration > 0 else { return [] }
        let valid = ranges.compactMap { range -> Self? in
            guard range.start.isFinite, range.end.isFinite else { return nil }
            let start = max(0, range.start), end = min(duration, range.end)
            return end > start ? Self(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var result: [Self] = []
        for range in valid {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = Self(start: last.start, end: max(last.end, range.end))
            } else { result.append(range) }
        }
        return result
    }
}

enum MPVPlaybackCachePolicy {
    static func allowsExtendedReadAhead(connected: Bool, expensive: Bool, constrained: Bool, wifiOrEthernet: Bool) -> Bool {
        connected && !expensive && !constrained && wifiOrEthernet
    }

    static func readAheadSeconds(extended: Bool, foreground: Bool, paused: Bool) -> String {
        if !foreground && paused { return "0" }
        // Large finite target; disk safeguards or EOF normally stop reading first.
        return extended && foreground ? "86400" : "120"
    }

    /// Main remote VOD sessions only. Auxiliary decoders and live streams retain defaults.
    static func options(enabled: Bool, url: URL) -> [String: String] {
        guard enabled, !url.isFileURL,
              !["rtsp", "rtsps", "rtp", "udp"].contains(url.scheme?.lowercased() ?? "") else { return [:] }
        return ["cache": "yes", "cache-secs": "120", "demuxer-seekable-cache": "yes",
                // MP4s and remote filesystems can interleave small reads across distant offsets.
                "stream-buffer-size": "1048576",
                "demuxer-max-bytes": "67108864", "demuxer-max-back-bytes": "33554432"]
    }
}

struct MPVReadSpeedSmoother {
    private var smoothedBytesPerSecond: Double?
    private var lastSampleAt: TimeInterval?
    private var publishedBytesPerSecond: Int64?

    /// Samples at the download center's cadence and uses its 65/35 exponential smoothing.
    /// The measurement is lazy so the source-rate calculation also stays on that cadence.
    mutating func update(idle: Bool, now: TimeInterval, measure: () -> Int64?) -> Int64? {
        if idle {
            smoothedBytesPerSecond = nil
            lastSampleAt = now
            publishedBytesPerSecond = nil
            return nil
        }

        let elapsed = now - (lastSampleAt ?? -.infinity)
        guard elapsed >= 0.9 else { return publishedBytesPerSecond }

        let target = Double(max(0, measure() ?? 0))
        if let current = smoothedBytesPerSecond {
            smoothedBytesPerSecond = (current * 0.65) + (target * 0.35)
        } else {
            smoothedBytesPerSecond = target
        }
        lastSampleAt = now

        if let value = smoothedBytesPerSecond, value >= 512 {
            publishedBytesPerSecond = Int64(clamping: Int(value.rounded()))
        } else {
            smoothedBytesPerSecond = nil
            publishedBytesPerSecond = nil
        }
        return publishedBytesPerSecond
    }
}
