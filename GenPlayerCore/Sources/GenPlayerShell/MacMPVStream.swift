#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
#if canImport(Libmpv)
import Libmpv
#endif

/// A cancellable blocking boundary for libmpv's demux thread. Readers remain async
/// and never borrow a browser/download connection. Neither AppKit nor the mpv
/// command queue waits on this condition.
final class MacMPVReadResult<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Value, Error>?
    func finish(_ value: Result<Value, Error>) {
        condition.lock(); defer { condition.unlock() }
        guard result == nil else { return }
        result = value; condition.broadcast()
    }
    func wait() throws -> Value {
        condition.lock(); defer { condition.unlock() }
        // Bound a broken reader even if it ignores Swift cancellation.
        let deadline = Date().addingTimeInterval(30)
        while result == nil {
            if !condition.wait(until: deadline) { throw URLError(.timedOut) }
        }
        return try result!.get()
    }
}

public final class MacMPVStream: @unchecked Sendable {
#if os(macOS) || os(iOS) || os(tvOS)
    private struct InputReadSample {
        let startedAt: TimeInterval
        let completedAt: TimeInterval
        let bytes: Int
    }
#endif

    private static let rangeCacheBlockSize: Int64 = 1_048_576

    public let url = URL(string: "genplayer://\(UUID().uuidString)/media")!
    private let metadata: @Sendable () async throws -> UInt64
    private let reader: @Sendable (UInt64, Int) async throws -> Data
    private let byteCache: MPVReadAheadByteCache
    private let lock = NSLock()
    private var cancelled = false
    private var cancelRead: (() -> Void)?
#if os(macOS) || os(iOS) || os(tvOS)
    private var inputReadSamples: [InputReadSample] = []
#endif
    // Only touched by the one demux thread. cancel() only touches the lock state.
    private var size: Int64 = 0
    private var offset: Int64 = 0
    private var opened = false

    public init(
        metadata: @escaping @Sendable () async throws -> UInt64,
        read: @escaping @Sendable (UInt64, Int) async throws -> Data,
        byteCache: MPVReadAheadByteCache? = nil
    ) {
        self.metadata = metadata
        self.reader = read
        self.byteCache = byteCache ?? MPVReadAheadByteCache()
    }

    func cancel() {
        lock.lock(); cancelled = true; let cancel = cancelRead; lock.unlock()
        cancel?()
    }

    /// Estimated bytes fetched through the remote reader during the trailing second.
    /// MPV's cache-speed includes hits served from this stream's in-memory ranges.
#if os(macOS) || os(iOS) || os(tvOS)
    func inputBytesPerSecond(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        inputReadSamples.removeAll { now - $0.completedAt > 2 }
        let windowStart = now - 1
        let bytes = inputReadSamples.reduce(into: 0.0) { total, sample in
            let duration = sample.completedAt - sample.startedAt
            guard duration > 0 else { return }
            let overlap = max(0, min(sample.completedAt, now) - max(sample.startedAt, windowStart))
            if overlap > 0 { total += Double(sample.bytes) * overlap / duration }
        }
        return bytes > 0 ? Int64(clamping: Int(bytes)) : nil
    }
#endif

    private func awaitRead<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let result = MacMPVReadResult<T>()
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        let task = Task.detached { do { result.finish(.success(try await operation())) } catch { result.finish(.failure(error)) } }
        cancelRead = { task.cancel(); result.finish(.failure(CancellationError())) }
        lock.unlock()
        defer { task.cancel(); lock.lock(); cancelRead = nil; lock.unlock() }
        let value = try result.wait()
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        return value
    }

    func open() -> Bool {
        lock.lock()
        guard !opened, !cancelled else { lock.unlock(); return false }
        opened = true // One registered URI, one playback stream.
        lock.unlock()
        guard let bytes = try? awaitRead(metadata), bytes > 0, bytes <= UInt64(Int64.max) else { return false }
        size = Int64(bytes); return true
    }

    func seek(_ target: Int64) -> Int64 {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped, target >= 0, target <= size else { return -1 }
        offset = target; return offset
    }

    func read(into destination: UnsafeMutableRawPointer, count: UInt64) -> Int64 {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { return -1 }
        if count == 0 || offset == size { return 0 }
        guard offset >= 0, offset < size else { return -1 }
        let start = (offset / Self.rangeCacheBlockSize) * Self.rangeCacheBlockSize
        let amount = Int(min(Self.rangeCacheBlockSize, size - start))
        guard let data = try? byteCache.dataOrFetch(at: start, isCancelled: { [weak self] in
            guard let self else { return true }
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.cancelled
        }, fetch: { [reader, weak self] in
            guard let self else { throw CancellationError() }
#if os(macOS) || os(iOS) || os(tvOS)
            let startedAt = ProcessInfo.processInfo.systemUptime
#endif
            let fetched = try self.awaitRead({ try await reader(UInt64(start), amount) })
            guard fetched.count == amount else { throw URLError(.badServerResponse) }
#if os(macOS) || os(iOS) || os(tvOS)
            let completedAt = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            self.inputReadSamples.append(InputReadSample(startedAt: startedAt, completedAt: completedAt, bytes: fetched.count))
            self.lock.unlock()
#endif
            return fetched
        }), data.count == amount else { return -1 }
        let index = Int(offset - start)
        guard index < data.count else { return -1 }
        let readAmount = Int(min(count, UInt64(data.count - index)))
        data.withUnsafeBytes { bytes in destination.copyMemory(from: bytes.baseAddress!.advanced(by: index), byteCount: readAmount) }
        offset += Int64(readAmount)
        return Int64(readAmount)
    }

    #if canImport(Libmpv)
    func register(on handle: OpaquePointer) -> Bool {
        mpv_stream_cb_add_ro(handle, "genplayer", Unmanaged.passUnretained(self).toOpaque(), { context, uri, info in
            guard let context, let uri, let info else { return -1 }
            let source = Unmanaged<MacMPVStream>.fromOpaque(context).takeUnretainedValue()
            guard String(cString: uri) == source.url.absoluteString, source.open() else { return -1 }
            info.pointee.cookie = Unmanaged.passRetained(source).toOpaque()
            info.pointee.read_fn = { cookie, bytes, count in
                guard let cookie, let bytes else { return -1 }
                return Unmanaged<MacMPVStream>.fromOpaque(cookie).takeUnretainedValue().read(into: bytes, count: count)
            }
            info.pointee.seek_fn = { cookie, offset in
                guard let cookie else { return -1 }
                return Unmanaged<MacMPVStream>.fromOpaque(cookie).takeUnretainedValue().seek(offset)
            }
            info.pointee.size_fn = { cookie in
                guard let cookie else { return -1 }
                return Unmanaged<MacMPVStream>.fromOpaque(cookie).takeUnretainedValue().size
            }
            info.pointee.cancel_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<MacMPVStream>.fromOpaque(cookie).takeUnretainedValue().cancel()
            }
            info.pointee.close_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<MacMPVStream>.fromOpaque(cookie).takeRetainedValue().cancel()
            }
            return 0
        }) >= 0
    }
    #endif
}
#endif
