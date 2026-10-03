#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
import Network

/// FTP ranges require a confirmed REST before RETR; the browsing client's pipelined
/// download API cannot guarantee this. This connection belongs only to audio extraction.
actor FTPAudioRangeSource: AudioRangeSource {
    private let url: URL
    private var control: AudioFTPConnection?
    private var expected: AudioFileVersion?
    private static let windowSize = 256 * 1024
    private static let transferLimit: UInt64 = 32 * 1024 * 1024
    private var window: (offset: UInt64, bytes: Data)?
    private var transferred: UInt64 = 0
    init(url: URL) { self.url = url }
    private func connection() async throws -> AudioFTPConnection {
        if let control { return control }
        guard let host = url.host, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["ftp", "ftps"].contains(parts.scheme ?? ""), !parts.path.isEmpty,
              ![parts.path, parts.user ?? "", parts.password ?? ""].contains(where: { $0.contains("\r") || $0.contains("\n") || $0.contains("\0") }) else {
            throw AudioRangeFailure.unsupported
        }
        let secure = parts.scheme == "ftps"
        let candidate = try AudioFTPConnection(host: host, port: parts.port ?? (secure ? 990 : 21), secure: secure)
        do {
            try await candidate.connect()
            guard try await candidate.response().code == 220 else { throw AudioRangeFailure.invalidResponse }
            let user = try await candidate.command("USER " + (parts.user ?? "anonymous"))
            if user.code == 331 {
                guard try await candidate.command("PASS " + (parts.password ?? "anonymous@")).code == 230 else { throw URLError(.userAuthenticationRequired) }
            } else if user.code != 230 { throw URLError(.userAuthenticationRequired) }
            guard try await candidate.command("TYPE I").code == 200 else { throw AudioRangeFailure.unsupported }
            if secure {
                guard try await candidate.command("PBSZ 0").code == 200,
                      try await candidate.command("PROT P").code == 200 else { throw AudioRangeFailure.unsupported }
            }
            control = candidate
            return candidate
        } catch { candidate.close(); throw error }
    }
    func metadata() async throws -> AudioFileVersion {
        do {
            let control = try await connection()
            let size = try await control.command("SIZE " + url.path)
            let date = try await control.command("MDTM " + url.path)
            guard size.code == 213, let bytes = UInt64(size.text.dropFirst(4)), bytes > 0,
                  date.code == 213, date.text.dropFirst(4).count >= 14,
                  date.text.dropFirst(4).allSatisfy({ $0.isNumber || $0 == "." }) else { throw AudioRangeFailure.unsupported }
            let version = AudioFileVersion(size: bytes, stamp: String(date.text.dropFirst(4)))
            if let expected, version != expected { throw AudioRangeFailure.changed }
            expected = version
            // The MP4 reader validates metadata at each index/segment boundary.
            // Keep the validated window, but start a fresh transfer allowance.
            transferred = 0
            return version
        } catch { invalidate(); throw error }
    }
    func read(offset: UInt64, count: Int) async throws -> Data {
        guard let expected, count > 0, count <= 1024 * 1024, offset < expected.size,
              UInt64(count) <= expected.size - offset else { throw AudioRangeFailure.invalidResponse }
        do {
            try Task.checkCancellation()
            var result = Data()
            while result.count < count {
                let position = offset + UInt64(result.count)
                let base = position / UInt64(Self.windowSize) * UInt64(Self.windowSize)
                if window?.offset != base {
                    let length = Int(min(UInt64(Self.windowSize), expected.size - base))
                    guard transferred <= Self.transferLimit - UInt64(length) else { throw AudioRangeFailure.unsupported }
                    let bytes = try await fetch(offset: base, count: length)
                    window = (base, bytes)
                }
                try Task.checkCancellation()
                guard let window else { throw AudioRangeFailure.invalidResponse }
                let start = Int(position - window.offset)
                let length = min(count - result.count, window.bytes.count - start)
                result.append(window.bytes.subdata(in: start..<(start + length)))
            }
            return result
        } catch { invalidate(); throw error }
    }
    private func invalidate() {
        control?.close(); control = nil; window = nil
    }
    private func fetch(offset: UInt64, count: Int) async throws -> Data {
        guard let host = url.host else { throw URLError(.badURL) }
        do {
            let control = try await connection()
            let passive = try await control.command("EPSV")
            let port: Int
            if passive.code == 229, let open = passive.text.firstIndex(of: "("), let close = passive.text[open...].firstIndex(of: ")") {
                let value = String(passive.text[passive.text.index(after: open)..<close])
                guard let delimiter = value.first, let number = value.split(separator: delimiter).last, let parsed = Int(number) else { throw AudioRangeFailure.invalidResponse }
                port = parsed
            } else {
                let response = try await control.command("PASV")
                guard response.code == 227, let open = response.text.firstIndex(of: "("), let close = response.text[open...].firstIndex(of: ")") else { throw AudioRangeFailure.unsupported }
                let numbers = response.text[response.text.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { throw AudioRangeFailure.invalidResponse }
                port = numbers[4] * 256 + numbers[5]
            }
            // Always use the authenticated control host, not a host supplied by PASV.
            let data = try AudioFTPConnection(host: host, port: port, secure: url.scheme == "ftps")
            let report = data.startReport()
            defer { data.close() }
            // TLS data handshakes may wait until the server accepts RETR.
            async let connected: Void = data.connect()
            guard try await control.command("REST \(offset)").code == 350 else { throw AudioRangeFailure.unsupported }
            let retrieve = try await control.command("RETR " + url.path)
            guard retrieve.code == 125 || retrieve.code == 150 else { throw AudioRangeFailure.invalidResponse }
            try await connected
            var result = Data()
            while result.count < count {
                try Task.checkCancellation()
                result += try await data.receive(maximum: min(64 * 1024, count - result.count))
            }
            data.close()
            // FTP cannot specify an end offset. Account for bytes already received
            // by TCP/TLS as well as the window consumed by the application.
            transferred += max(UInt64(count), try await data.receivedBytes(report))
            guard transferred <= Self.transferLimit else { throw AudioRangeFailure.unsupported }
            // NOOP is a reply fence after ABOR, draining 426/226/225 without leaving
            // the next range's REST to consume an old transfer's completion.
            try await control.send("ABOR\r\nNOOP\r\n")
            var synchronized = false
            for _ in 0..<8 {
                let response = try await control.response()
                if response.code == 200 { synchronized = true; break }
                guard [225, 226, 426, 500, 502].contains(response.code) else { throw AudioRangeFailure.invalidResponse }
            }
            guard synchronized else { throw AudioRangeFailure.invalidResponse }
            try Task.checkCancellation()
            return result
        } catch { invalidate(); throw error }
    }
}

private final class AudioNetworkReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}

private final class AudioFTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    init(host: String, port: Int, secure: Bool) throws {
        guard (1...65535).contains(port), let port = NWEndpoint.Port(rawValue: UInt16(port)) else { throw URLError(.badURL) }
        connection = NWConnection(host: .init(host), port: port, using: secure ? .tls : .tcp)
    }
    deinit { connection.cancel() }
    func close() { connection.cancel() }
    func startReport() -> NWConnection.PendingDataTransferReport { connection.startDataTransferReport() }
    func receivedBytes(_ report: NWConnection.PendingDataTransferReport) async throws -> UInt64 {
        try await operation { reply in
            report.collect(queue: .global(qos: .utility)) { value in
                reply.finish(.success(value.aggregatePathReport.receivedTransportByteCount))
            }
        }
    }
    private func operation<T: Sendable>(_ begin: @escaping (AudioNetworkReply<T>) -> Void) async throws -> T {
        let reply = AudioNetworkReply<T>()
        let timeout = DispatchWorkItem { [connection] in reply.finish(.failure(URLError(.timedOut))); connection.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in reply.install(continuation); begin(reply) }
        } onCancel: { reply.finish(.failure(CancellationError())); self.connection.cancel() }
    }
    func connect() async throws {
        try await operation { (reply: AudioNetworkReply<Void>) in
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: reply.finish(.success(()))
                case .failed(let error): reply.finish(.failure(error))
                case .cancelled: reply.finish(.failure(CancellationError()))
                default: break
                }
            }
            self.connection.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
    func send(_ string: String) async throws {
        try await operation { (reply: AudioNetworkReply<Void>) in
            self.connection.send(content: Data(string.utf8), completion: .contentProcessed { error in
                reply.finish(error.map { .failure($0) } ?? .success(()))
            })
        }
    }
    func receive(maximum: Int) async throws -> Data {
        try await operation { reply in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error { reply.finish(.failure(error)) }
                else if let data, !data.isEmpty { reply.finish(.success(data)) }
                else { reply.finish(.failure(AudioRangeFailure.invalidResponse)) }
            }
        }
    }
    func command(_ string: String) async throws -> (code: Int, text: String) {
        guard !string.contains("\r"), !string.contains("\n"), !string.contains("\0") else { throw URLError(.badURL) }
        try await send(string + "\r\n")
        return try await response()
    }
    private func line() async throws -> String {
        while true {
            if let end = buffer.range(of: Data([13, 10])) {
                let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                return line
            }
            guard buffer.count < 8192 else { throw AudioRangeFailure.invalidResponse }
            buffer += try await receive(maximum: 4096)
        }
    }
    func response() async throws -> (code: Int, text: String) {
        let first = try await line()
        guard first.count >= 4, let code = Int(first.prefix(3)) else { throw AudioRangeFailure.invalidResponse }
        if first.dropFirst(3).first == " " { return (code, first) }
        guard first.dropFirst(3).first == "-" else { throw AudioRangeFailure.invalidResponse }
        for _ in 0..<32 {
            let next = try await line()
            if next.hasPrefix("\(code) ") { return (code, next) }
        }
        throw AudioRangeFailure.invalidResponse
    }
}
#endif
