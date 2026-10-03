#if os(macOS) || os(iOS) || os(tvOS)
import Foundation

public struct AudioFileVersion: Sendable, Equatable {
    public let size: UInt64
    public let stamp: String
    public init(size: UInt64, stamp: String) { self.size = size; self.stamp = stamp }
}

protocol AudioRangeSource: Sendable {
    func metadata() async throws -> AudioFileVersion
    func read(offset: UInt64, count: Int) async throws -> Data
}

enum AudioRangeFailure: Error { case unsupported, changed, invalidResponse }

/// Serialize even across async suspension and retry, without blocking an executor thread.
actor AudioReadGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

final class AudioReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

protocol BlockingAudioFile: AnyObject {
    func metadata() throws -> AudioFileVersion
    func read(offset: UInt64, count: Int, cancellation: AudioReadCancellation) throws -> Data
}

/// Isolated native file handles stay on a private queue, including teardown.
final class BlockingAudioRangeSource: AudioRangeSource, @unchecked Sendable {
    private final class State: @unchecked Sendable { var file: BlockingAudioFile? }
    private let state = State()
    private let queue = DispatchQueue(label: "GenPlayer.audio.range", qos: .utility)
    private let open: @Sendable () throws -> BlockingAudioFile
    init(open: @escaping @Sendable () throws -> BlockingAudioFile) { self.open = open }
    deinit { let state = state; queue.async { state.file = nil } }
    func metadata() async throws -> AudioFileVersion { try await operation { file, _ in try file.metadata() } }
    func read(offset: UInt64, count: Int) async throws -> Data {
        try await operation { try $0.read(offset: offset, count: count, cancellation: $1) }
    }
    private func operation<T: Sendable>(_ body: @escaping @Sendable (BlockingAudioFile, AudioReadCancellation) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let state = state, open = open, cancellation = AudioReadCancellation()
        let value: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        if state.file == nil { state.file = try open() }
                        try cancellation.check()
                        guard let file = state.file else { throw AudioRangeFailure.invalidResponse }
                        let result = try body(file, cancellation)
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch { state.file = nil; continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return value
    }
}
#endif
