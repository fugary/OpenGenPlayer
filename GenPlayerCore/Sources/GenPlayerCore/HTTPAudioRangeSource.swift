#if os(macOS) || os(iOS) || os(tvOS)
import Foundation

/// A HTTP response is authorized for buffering only after exact range validation.
enum HTTPAudioRangeValidation {
    static func version(_ response: HTTPURLResponse, offset: UInt64, count: Int) throws -> AudioFileVersion {
        guard response.statusCode == 206, count > 0,
              (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity",
              let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else {
            throw AudioRangeFailure.unsupported
        }
        let fields = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, let size = UInt64(fields[1]), size > 0 else { throw AudioRangeFailure.invalidResponse }
        let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = UInt64(bounds[0]), let last = UInt64(bounds[1]),
              first == offset, last >= first, last < size, last - first == UInt64(count - 1) else {
            throw AudioRangeFailure.invalidResponse
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length") {
            guard UInt64(length) == UInt64(count) else { throw AudioRangeFailure.invalidResponse }
        }
        let stamp: String
        if let etag = response.value(forHTTPHeaderField: "ETag"), etag.count >= 2,
           etag.hasPrefix("\""), etag.hasSuffix("\""),
           !etag.dropFirst().dropLast().unicodeScalars.contains(where: { $0.value < 33 || $0.value == 34 || $0.value == 127 }) {
            stamp = "etag:" + etag
        } else if let date = response.value(forHTTPHeaderField: "Last-Modified"), date.count <= 64 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            guard formatter.date(from: date) != nil else { throw AudioRangeFailure.unsupported }
            stamp = "date:" + date
        } else { throw AudioRangeFailure.unsupported }
        return .init(size: size, stamp: stamp)
    }
}

actor HTTPAudioRangeSource: AudioRangeSource {
    private let request: @Sendable () async throws -> URLRequest
    private var expected: AudioFileVersion?
    private let session = HTTPAudioRangeSession()
    deinit { session.close() }
    init(request: @escaping @Sendable () async throws -> URLRequest) { self.request = request }
    func metadata() async throws -> AudioFileVersion {
        let result = try await fetch(offset: 0, count: 1, expected: nil)
        if let expected, result.version != expected { throw AudioRangeFailure.changed }
        expected = result.version
        return result.version
    }
    func read(offset: UInt64, count: Int) async throws -> Data {
        guard let expected, count > 0, offset < expected.size, UInt64(count) <= expected.size - offset else {
            throw AudioRangeFailure.invalidResponse
        }
        return try await fetch(offset: offset, count: count, expected: expected).data
    }
    private func fetch(offset: UInt64, count: Int, expected: AudioFileVersion?) async throws -> HTTPAudioRangeTransfer.Result {
        try Task.checkCancellation()
        var request = try await request()
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              count > 0, count <= 1024 * 1024, offset <= UInt64(Int64.max) - UInt64(count) else {
            throw AudioRangeFailure.unsupported
        }
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue("bytes=\(offset)-\(offset + UInt64(count - 1))", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let expected { request.setValue(String(expected.stamp.dropFirst(5)), forHTTPHeaderField: "If-Range") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return try await HTTPAudioRangeTransfer(offset: offset, count: count, expected: expected, session: session).run(request)
    }
}

private final class HTTPAudioRangeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable { let data: Data; let version: AudioFileVersion }
    private let offset: UInt64, count: Int, expected: AudioFileVersion?
    private var version: AudioFileVersion?, data = Data(), redirects = 0
    private var continuation: CheckedContinuation<Result, Error>?
    private let session: HTTPAudioRangeSession
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var cancelled = false
    init(offset: UInt64, count: Int, expected: AudioFileVersion?, session: HTTPAudioRangeSession) {
        self.offset = offset; self.count = count; self.expected = expected; self.session = session
    }
    func run(_ request: URLRequest) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                task = session.task(request: request, transfer: self)
                let task = task
                lock.unlock()
                task?.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        }
    }
    private func finish(_ result: Swift.Result<Result, Error>) {
        lock.lock()
        let continuation = continuation, task = task
        self.continuation = nil; self.task = nil
        let cancelled = cancelled
        lock.unlock()
        if let task { session.remove(task); task.cancel() }
        continuation?.resume(with: cancelled ? .failure(CancellationError()) : result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw AudioRangeFailure.invalidResponse }
            let version = try HTTPAudioRangeValidation.version(response, offset: offset, count: count)
            if let expected, version != expected { throw AudioRangeFailure.changed }
            self.version = version
            completionHandler(.allow)
        } catch { completionHandler(.cancel); finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard version != nil, chunk.count <= count - data.count else {
            finish(.failure(AudioRangeFailure.invalidResponse)); return
        }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let version, data.count == count else { finish(.failure(AudioRangeFailure.invalidResponse)); return }
        finish(.success(.init(data: data, version: version)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let old = response.url, let new = request.url,
              ["http", "https"].contains(new.scheme?.lowercased() ?? ""), new.user == nil, new.password == nil,
              !(old.scheme == "https" && new.scheme != "https") else {
            completionHandler(nil); finish(.failure(AudioRangeFailure.unsupported)); return
        }
        var redirected = request
        // Signed target URLs carry their own grant; never forward origin secrets cross-origin.
        if old.scheme != new.scheme || old.host != new.host || old.port != new.port {
            for field in ["Authorization", "Cookie", "Proxy-Authorization"] { redirected.setValue(nil, forHTTPHeaderField: field) }
        }
        for field in ["Range", "If-Range", "Accept-Encoding"] {
            redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: field), forHTTPHeaderField: field)
        }
        completionHandler(redirected)
    }
}

private final class HTTPAudioRangeSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: HTTPAudioRangeTransfer] = [:]
    private var session: URLSession!
    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }
    func close() { session.invalidateAndCancel() }
    func task(request: URLRequest, transfer: HTTPAudioRangeTransfer) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock(); transfers[task.taskIdentifier] = transfer; lock.unlock()
        return task
    }
    func remove(_ task: URLSessionTask) {
        lock.lock(); transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
    }
    private func transfer(_ task: URLSessionTask) -> HTTPAudioRangeTransfer? {
        lock.lock(); defer { lock.unlock() }; return transfers[task.taskIdentifier]
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(dataTask) else { completionHandler(.cancel); return }
        transfer.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(task)?.urlSession(session, task: task, didCompleteWithError: error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let transfer = transfer(task) else { completionHandler(nil); return }
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}
#endif
