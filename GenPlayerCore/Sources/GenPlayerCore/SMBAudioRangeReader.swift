#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
import SMB2

/// Dedicated read-only subtitle connection. All synchronous libsmb2 operations run on one
/// private queue, never on the main actor or the browsing/playback connection.
public final class SMBAudioRangeReader: @unchecked Sendable {
    public struct Metadata: Sendable, Equatable {
        public let size: UInt64
        public let version: String
    }
    private final class State: @unchecked Sendable {
        var context: UnsafeMutablePointer<smb2_context>?
        var file: OpaquePointer?
        func close() {
            // Destroy the isolated context directly on cancellation/teardown, avoiding a
            // synchronous network CLOSE/DISCONNECT round-trip in a deinitializer.
            if let context { smb2_destroy_context(context) }
            context = nil; file = nil
        }
        deinit { close() }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }
    private let queue = DispatchQueue(label: "GenPlayer.subtitle.smb", qos: .utility)
    private let state = State()
    private let url: URL
    public init(url: URL) { self.url = url }
    deinit {
        let state = state
        queue.async { state.close() }
    }

    public func metadata() async throws -> Metadata {
        try await operation { state, cancellation in
            try cancellation.check()
            guard let context = state.context, let file = state.file else { throw URLError(.cannotOpenFile) }
            var info = smb2_stat_64()
            guard smb2_fstat(context, file, &info) == 0, info.smb2_size > 0 else { throw URLError(.cannotOpenFile) }
            return Metadata(size: info.smb2_size, version: "\(info.smb2_mtime):\(info.smb2_mtime_nsec)")
        }
    }

    public func read(offset: UInt64, count: Int) async throws -> Data {
        guard count > 0, count <= 1024 * 1024, offset <= UInt64(Int64.max) - UInt64(count) else { throw URLError(.badURL) }
        return try await operation { state, cancellation in
            guard let context = state.context, let file = state.file else { throw URLError(.cannotOpenFile) }
            let maximum = Int(smb2_get_max_read_size(context))
            guard maximum > 0 else { throw URLError(.cannotDecodeContentData) }
            var result = Data()
            while result.count < count {
                try cancellation.check()
                let length = min(maximum, count - result.count)
                var part = Data(count: length)
                let received = part.withUnsafeMutableBytes { buffer in
                    smb2_pread(context, file, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                               UInt32(length), offset + UInt64(result.count))
                }
                guard received > 0, received <= length else { throw URLError(.cannotDecodeContentData) }
                result += part.prefix(Int(received))
            }
            return result
        }
    }

    private func operation<T: Sendable>(_ body: @escaping @Sendable (State, Cancellation) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let state = state, url = url, cancellation = Cancellation()
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        if state.file == nil {
                            #if os(iOS)
                            // Resolve Bonjour names only when reading, off the player's main thread.
                            let resolved = RuntimeNetworkAddressResolver.runtimeURL(from: url)
                            try cancellation.check()
                            try Self.open(resolved, state: state)
                            #else
                            try Self.open(url, state: state)
                            #endif
                        }
                        try cancellation.check()
                        let value = try body(state, cancellation)
                        try cancellation.check()
                        continuation.resume(returning: value)
                    } catch {
                        state.close()
                        // Never include libsmb2's error text or a credential-bearing URL in diagnostics.
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return result
    }

    private static func open(_ url: URL, state: State) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "smb",
              let host = parts.host, !host.isEmpty, parts.query == nil, parts.fragment == nil else { throw URLError(.badURL) }
        guard ![host, parts.path, parts.user ?? "", parts.password ?? ""].contains(where: { $0.contains("\0") }) else {
            throw URLError(.badURL)
        }
        let components = parts.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, !components.contains(".."),
              let context = smb2_init_context() else { throw URLError(.badURL) }
        state.context = context
        smb2_set_timeout(context, 15)
        smb2_set_security_mode(context, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
        let login = SMBAudioLogin(user: parts.user)
        smb2_set_domain(context, login.domain)
        smb2_set_workstation(context, login.workstation)
        smb2_set_user(context, login.user)
        smb2_set_password(context, parts.password ?? "")
        let server = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let address = server + (parts.port.map { ":\($0)" } ?? "")
        guard smb2_connect_share(context, address, String(components[0]), login.user) == 0 else { throw URLError(.cannotConnectToHost) }
        let path = components.dropFirst().joined(separator: "/")
        guard let file = smb2_open(context, path, O_RDONLY) else { throw URLError(.cannotOpenFile) }
        state.file = file
    }
}
#endif
