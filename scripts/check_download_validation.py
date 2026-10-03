#!/usr/bin/env python3
"""Compile current download validators/delegates and test callbacks without network or GUI."""
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def extract(text, declaration):
    start = text.index(declaration)
    return text[start:text.index('\n}\n', start) + 3]


parts = ['import Foundation', (REPO / 'GenPlayerCore/Sources/GenPlayerCore/DownloadFileValidation.swift').read_text()]
runners = []
for prefix, path, managed in [
    ('IOS', 'GenPlayer/Source/Services/NetworkService.swift', True),
    ('Core', 'GenPlayerCore/Sources/GenPlayerCore/DownloadCenterService.swift', True),
    ('Network', 'GenPlayerCore/Sources/GenPlayerCore/AppNetworkService.swift', False),
]:
    source = (REPO / path).read_text()
    names = ['HTTPDownloadSessionDelegate'] + (['ManagedHTTPDownload'] if managed else [])
    for original in names:
        name = prefix + original
        chunk = extract(source, 'private final class ' + original + ':')
        parts.append(chunk.replace(original, name))
        is_managed = original == 'ManagedHTTPDownload'
        if is_managed:
            parts.append(f'''extension {name} {{
    func installContinuation(_ value: CheckedContinuation<URL, Error>) {{ continuation = value }}
}}''')
        initializer = 'request: URLRequest(url: URL(string: "https://example.invalid/file.mp4")!), progressHandler: nil' if is_managed else 'destinationURL: destination, progressHandler: nil'
        destination_line = '' if is_managed else 'let destination = root.appendingPathComponent(UUID().uuidString)'
        parts.append(f'''
private func check{name}(status: Int, headers: [String: String], bytes: Int, root: URL) async throws -> Bool {{
    let source = root.appendingPathComponent(UUID().uuidString)
    {destination_line}
    try Data(repeating: 65, count: bytes).write(to: source)
    defer {{ try? FileManager.default.removeItem(at: source) }}
    let task = MockDownloadTask(status: status, headers: headers)
    let delegate = {name}({initializer})
    do {{
        let result: URL = try await withCheckedThrowingContinuation {{ continuation in
            delegate.installContinuation(continuation)
            delegate.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: source)
        }}
        let actual = try Data(contentsOf: result).count
        try FileManager.default.removeItem(at: result)
        return actual == bytes
    }} catch {{
        return false
    }}
}}
''')
        runners.append(f'("{name}", check{name})')

# Use the production callback methods with in-memory event recording. The staging
# stand-in avoids writing to application support or initializing background sessions.
background_runners = []
for prefix, path in [
    ('IOS', 'GenPlayer/Source/Services/BackgroundDownloadSessionManager.swift'),
    ('Core', 'GenPlayerCore/Sources/GenPlayerCore/BackgroundDownloadSessionManager.swift'),
]:
    source = (REPO / path).read_text()
    callbacks = []
    for signature in [
        'func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL)',
        'func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)',
    ]:
        start = source.index(signature)
        callbacks.append(source[start:source.index('\n    }\n', start) + 6])
    name = prefix + 'BackgroundCallbacks'
    parts.append(f'''
private final class {name} {{
    let lock = NSLock()
    var completionErrors: [Int: Error] = [:]
    let recorder = BackgroundRecorder()
    func notifyDelegate(_ action: (BackgroundRecorder) -> Void) {{ action(recorder) }}
    func stageDownloadedFile(from location: URL, downloadID: UUID, task: URLSessionDownloadTask) throws -> URL {{ location }}
    {chr(10).join(callbacks)}
}}
private func check{name}(status: Int, headers: [String: String], bytes: Int, root: URL) async throws -> Bool {{
    let source = root.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 65, count: bytes).write(to: source)
    defer {{ try? FileManager.default.removeItem(at: source) }}
    let task = MockDownloadTask(status: status, headers: headers)
    task.taskDescription = UUID().uuidString
    let manager = {name}()
    manager.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: source)
    precondition(manager.recorder.completions == 0, "Premature completion event")
    manager.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
    precondition(manager.recorder.completions == 1, "Missing or duplicate completion event")
    precondition(manager.completionErrors.isEmpty, "Leaked callback error")
    return manager.recorder.finished == 1 && manager.recorder.error == nil
}}
''')
    background_runners.append(f'("{name}", check{name})')
runners += background_runners
parts.append('''
private final class BackgroundRecorder {
    var finished = 0
    var completions = 0
    var error: Error?
    func backgroundDownloadSessionManager(_ manager: AnyObject, didFinishDownloading id: UUID, to url: URL) { finished += 1 }
    func backgroundDownloadSessionManager(_ manager: AnyObject, didCompleteDownload id: UUID, error: Error?, resumeData: Data?) {
        completions += 1
        self.error = error
    }
}
''')

parts.append('''
private enum HTTPManagedDownloadInterruption: Error { case paused(Data?) }
private final class MockDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    let mockResponse: URLResponse
    init(status: Int, headers: [String: String]) {
        mockResponse = HTTPURLResponse(url: URL(string: "https://example.invalid/file.mp4")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        super.init()
    }
    override var response: URLResponse? { mockResponse }
}
@main struct Audit {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        typealias Runner = (Int, [String: String], Int, URL) async throws -> Bool
        let runners: [(String, Runner)] = [RUNNERS]
        let cases: [(Int, [String: String], Int, Bool)] = [
            (200, ["Content-Length": "10"], 10, true),
            (200, ["Content-Length": "10"], 9, false),
            (200, ["Content-Length": "10"], 11, false),
            (200, ["Content-Length": "0"], 0, true),
            (200, [:], 10, true),
            (200, ["Content-Length": "5", "Content-Encoding": "gzip"], 10, true),
            (206, ["Content-Range": "bytes 5-9/10", "Content-Length": "5"], 10, true),
            (206, ["Content-Range": "bytes 5-9/10", "Content-Length": "5"], 5, false),
            (206, ["Content-Range": "bytes 0-4/10"], 5, false),
            (206, ["Content-Range": "bytes 0-9/*"], 10, false),
            (206, ["Content-Range": "bytes 0-9/10", "Content-Encoding": "gzip"], 10, false),
            (206, [:], 10, false),
            (204, [:], 0, false),
            (205, [:], 0, false),
            (302, [:], 10, false),
            (401, [:], 10, false),
            (403, [:], 10, false),
            (404, [:], 10, false),
            (416, [:], 10, false),
            (500, [:], 10, false)
        ]
        var count = 0
        for (name, run) in runners {
            for (status, headers, bytes, accepted) in cases {
                let actual = try await run(status, headers, bytes, root)
                precondition(actual == accepted, "\\(name) failed: HTTP \\(status), headers=\\(headers), bytes=\\(bytes)")
                count += 1
            }
        }
        let file = root.appendingPathComponent("file")
        try Data(repeating: 65, count: 10).write(to: file)
        for expected in [Int64(10), nil] as [Int64?] {
            let bytes = try DownloadFileValidation.validateFile(at: file, expectedBytes: expected)
            precondition(bytes == 10)
            count += 1
        }
        for expected: Int64 in [0, 9, 11] {
            do {
                try DownloadFileValidation.validateFile(at: file, expectedBytes: expected)
                fatalError("Accepted mismatched file size")
            } catch DownloadFileValidation.Failure.incompleteFile { count += 1 }
        }
        do {
            try DownloadFileValidation.validateHTTP(response: nil, fileURL: file)
            fatalError("Accepted missing HTTP response")
        } catch DownloadFileValidation.Failure.invalidResponse { count += 1 }
        print("PASS: \\(count) download validation/delegate cases; no network requests or App launch")
    }
}
'''.replace('RUNNERS', ', '.join(runners)))
with tempfile.TemporaryDirectory(prefix='GenPlayerDownloadChecks.') as temp:
    build = Path(temp)
    swift = build / 'Checks.swift'
    swift.write_text('\n'.join(parts))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(build / 'modules'), str(swift), '-o', str(build / 'checks')], check=True)
    subprocess.run([str(build / 'checks')], check=True)
