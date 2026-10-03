#if os(macOS) || os(iOS) || os(tvOS)
import Foundation

/// Bounded, in-memory raw media blocks shared by the primary MPV stream and
/// independent preview streams for one playback attempt.
public final class MPVReadAheadByteCache: @unchecked Sendable {
    public static let blockSize = 1_048_576

    struct AudioSubtitleReadUsage: Equatable, Sendable {
        let reusedBytes: UInt64
        let sourceBytes: UInt64
    }

    private let lock = NSCondition()
    private let maximumBlocks: Int
    private var fetchingOffsets = Set<Int64>()
    private var blocks: [Int64: Data] = [:]
    private var mostRecentFirst: [Int64] = []
    private var audioSubtitleReusedBytes: UInt64 = 0
    private var audioSubtitleSourceBytes: UInt64 = 0

    public init(maximumBytes: Int = 8 * 1_048_576) {
        maximumBlocks = max(1, maximumBytes / Self.blockSize)
    }

    func dataOrFetch(
        at offset: Int64,
        isCancelled: () -> Bool,
        fetch: () throws -> Data
    ) throws -> Data {
        lock.lock()
        while true {
            guard !isCancelled() else {
                lock.unlock()
                throw CancellationError()
            }
            if let data = blocks[offset] {
                touch(offset)
                lock.unlock()
                return data
            }

            if !fetchingOffsets.contains(offset) {
                fetchingOffsets.insert(offset)
                lock.unlock()
                break
            }

            _ = lock.wait(until: Date().addingTimeInterval(0.1))
        }

        do {
            let data = try fetch()
            lock.lock()
            if !data.isEmpty {
                blocks[offset] = data
                touch(offset)
                while mostRecentFirst.count > maximumBlocks {
                    blocks[mostRecentFirst.removeLast()] = nil
                }
            }
            fetchingOffsets.remove(offset)
            lock.broadcast()
            lock.unlock()
            return data
        } catch {
            lock.lock()
            fetchingOffsets.remove(offset)
            lock.broadcast()
            lock.unlock()
            throw error
        }
    }

    /// Reuses blocks already fetched by the active MPV stream. Misses stay on the
    /// caller's independent reader; this never reads libmpv's private demux cache.
    func readForAudioSubtitle(
        at offset: UInt64,
        count: Int,
        fallback: @escaping @Sendable (UInt64, Int) async throws -> Data
    ) async throws -> Data {
        guard count >= 0, count <= 32 * 1_048_576,
              offset <= UInt64(Int64.max), UInt64(count) <= UInt64(Int64.max) - offset else {
            throw URLError(.badURL)
        }
        guard count > 0 else { return Data() }

        let blockSize = UInt64(Self.blockSize)
        var result = Data(capacity: count)
        var cursor = offset
        let end = offset + UInt64(count)
        while cursor < end {
            try Task.checkCancellation()
            let blockOffset = (cursor / blockSize) * blockSize
            let blockStart = Int64(blockOffset)
            let withinBlock = Int(cursor - blockOffset)
            let remaining = Int(end - cursor)

            let cached = cachedBlock(at: blockStart)
            if let cached, withinBlock < cached.count {
                let length = min(remaining, cached.count - withinBlock)
                result.append(cached[withinBlock..<(withinBlock + length)])
                recordAudioSubtitleRead(reused: length, source: 0)
                cursor += UInt64(length)
            } else {
                let length = min(remaining, Self.blockSize - withinBlock)
                let bytes = try await fallback(cursor, length)
                guard bytes.count == length else { throw URLError(.badServerResponse) }
                result.append(bytes)
                recordAudioSubtitleRead(reused: 0, source: length)
                cursor += UInt64(length)
            }
        }
        return result
    }

    func audioSubtitleReadUsage() -> AudioSubtitleReadUsage {
        lock.lock(); defer { lock.unlock() }
        return AudioSubtitleReadUsage(reusedBytes: audioSubtitleReusedBytes,
                                      sourceBytes: audioSubtitleSourceBytes)
    }

    private func cachedBlock(at offset: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = blocks[offset] else { return nil }
        touch(offset)
        return data
    }

    private func recordAudioSubtitleRead(reused: Int, source: Int) {
        lock.lock(); defer { lock.unlock() }
        audioSubtitleReusedBytes &+= UInt64(max(0, reused))
        audioSubtitleSourceBytes &+= UInt64(max(0, source))
    }

    private func touch(_ offset: Int64) {
        mostRecentFirst.removeAll { $0 == offset }
        mostRecentFirst.insert(offset, at: 0)
    }
}
#endif
