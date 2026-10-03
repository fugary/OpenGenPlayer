#if os(tvOS)
import Foundation
import Darwin
import UIKit
import GenPlayerCore

public enum TVNetworkHelper {
    public static func getLocalIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidate: String?
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 {
                continue
            }
            guard let sa = interface.ifa_addr else { continue }
            let addrFamily = sa.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buffer)
                    // Prefer Wi-Fi (en0) or Ethernet (en1) on Apple TV
                    if name == "en0" || name == "en1" {
                        return ip
                    }
                    if candidate == nil {
                        candidate = ip
                    }
                }
            }
        }
        return candidate
    }
}

public final class TVLocalPairingServer: ObservableObject {
    public struct PairingResult {
        public let accessToken: String
        public let refreshToken: String
        public let displayName: String
        public let serverType: ServerConfig.ServerType
    }

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var port: Int = 0
    @Published public private(set) var localIP: String = ""
    @Published public private(set) var secret: String = ""
    @Published public private(set) var pairingURL: String = ""
    @Published public private(set) var lastStatusMessage: String = ""
    @Published public private(set) var isPaired: Bool = false

    private var listeningSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "com.genplayer.tvpairing", qos: .userInitiated)
    private var activeSessions: [Int32: TVPairingClientSession] = [:]
    private let lock = NSLock()
    private let serverType: ServerConfig.ServerType

    public var onPairingSuccess: ((PairingResult) -> Void)?

    public init(serverType: ServerConfig.ServerType) {
        self.serverType = serverType
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> String {
        if isRunning { return pairingURL }

        let ip = TVNetworkHelper.getLocalIPv4Address() ?? "127.0.0.1"
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let randomSecret = String((0..<6).compactMap { _ in chars.randomElement() })

        do {
            let assignedPort = try bindAndListen()
            let url = "http://\(ip):\(assignedPort)/pair?secret=\(randomSecret)&type=\(serverType.rawValue)"
            let applyState = {
                self.localIP = ip
                self.secret = randomSecret
                self.port = assignedPort
                self.pairingURL = url
                self.isRunning = true
                self.lastStatusMessage = platformShellString("Waiting for authorization...")
            }
            if Thread.isMainThread {
                applyState()
            } else {
                DispatchQueue.main.sync {
                    applyState()
                }
            }
            return url
        } catch {
            let errDesc = error.localizedDescription
            if Thread.isMainThread {
                self.lastStatusMessage = errDesc
            } else {
                DispatchQueue.main.async {
                    self.lastStatusMessage = errDesc
                }
            }
            return ""
        }
    }

    public func stop() {
        lock.lock()
        acceptSource?.cancel()
        acceptSource = nil
        let sock = listeningSocket
        listeningSocket = -1
        let sessions = Array(activeSessions.values)
        activeSessions.removeAll()
        lock.unlock()

        if sock >= 0 {
            Darwin.close(sock)
        }
        for s in sessions {
            s.close()
        }
        let applyState = {
            self.port = 0
            self.isRunning = false
        }
        if Thread.isMainThread {
            applyState()
        } else {
            DispatchQueue.main.async {
                applyState()
            }
        }
    }

    private func bindAndListen() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "TVLocalPairingServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket: \(errno)"])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var candidatePort: UInt16 = 8899
        var bound = false

        while candidatePort <= 8910 {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidatePort.bigEndian
            addr.sin_addr.s_addr = inet_addr("0.0.0.0")

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 {
                bound = true
                break
            }
            candidatePort += 1
        }

        if !bound {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("0.0.0.0")

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes != 0 {
                let err = errno
                Darwin.close(fd)
                throw NSError(domain: "TVLocalPairingServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to bind socket: \(err)"])
            }
        }

        guard Darwin.listen(fd, 10) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: "TVLocalPairingServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to listen: \(err)"])
        }

        var actualAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getSockRes = withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &addrLen)
            }
        }
        guard getSockRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: "TVLocalPairingServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to get sock name: \(err)"])
        }

        let assignedPort = Int(UInt16(bigEndian: actualAddr.sin_port))
        self.listeningSocket = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serverQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.acceptSource = source

        return assignedPort
    }

    private func acceptConnections() {
        while true {
            var clientAddr = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listeningSocket, $0, &clientLen)
                }
            }
            guard clientFd >= 0 else { break }

            let flags = fcntl(clientFd, F_GETFL, 0)
            _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)

            let session = TVPairingClientSession(
                clientSocket: clientFd,
                serverType: serverType,
                expectedSecret: secret,
                localIP: localIP,
                port: port,
                queue: serverQueue
            )

            session.onFinish = { [weak self] fd in
                self?.removeSession(fd: fd)
            }

            session.onSuccess = { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isPaired = true
                    self.lastStatusMessage = platformShellString("Authorization successful!")
                    self.onPairingSuccess?(result)
                }
            }

            lock.lock()
            activeSessions[clientFd] = session
            lock.unlock()

            session.start()
        }
    }

    private func removeSession(fd: Int32) {
        lock.lock()
        activeSessions.removeValue(forKey: fd)
        lock.unlock()
    }
}

private final class TVPairingClientSession {
    let clientSocket: Int32
    let serverType: ServerConfig.ServerType
    let expectedSecret: String
    let localIP: String
    let port: Int
    let queue: DispatchQueue

    var onFinish: ((Int32) -> Void)?
    var onSuccess: ((TVLocalPairingServer.PairingResult) -> Void)?

    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var isClosed = false

    init(clientSocket: Int32, serverType: ServerConfig.ServerType, expectedSecret: String, localIP: String, port: Int, queue: DispatchQueue) {
        self.clientSocket = clientSocket
        self.serverType = serverType
        self.expectedSecret = expectedSecret
        self.localIP = localIP
        self.port = port
        self.queue = queue
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleRead()
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.clientSocket >= 0 {
                Darwin.close(self.clientSocket)
            }
        }
        source.resume()
        self.readSource = source
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        onFinish?(clientSocket)
    }

    private func handleRead() {
        var temp = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(clientSocket, &temp, temp.count)
        if bytesRead > 0 {
            buffer.append(temp, count: bytesRead)
            checkBuffer()
        } else if bytesRead == 0 {
            close()
        } else {
            if errno != EAGAIN && errno != EWOULDBLOCK {
                close()
            }
        }
    }

    private func checkBuffer() {
        guard let requestString = String(data: buffer, encoding: .utf8) else { return }
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let method = parts[0].uppercased()
        let path = parts[1]

        if method == "GET" && (path.hasPrefix("/pair") || path == "/") {
            serveLandingPage(path: path)
            close()
        } else if method == "POST" && path == "/api/pair" {
            guard let headerEndRange = requestString.range(of: "\r\n\r\n") else { return }
            let bodyString = String(requestString[headerEndRange.upperBound...])

            var contentLength: Int? = nil
            for line in lines {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    contentLength = Int(val)
                    break
                }
            }

            if let len = contentLength {
                if bodyString.utf8.count < len {
                    return
                }
            }

            handleApiPair(bodyString: bodyString)
            close()
        } else if method == "OPTIONS" {
            sendOptionsResponse()
            close()
        }
    }

    private func serveLandingPage(path: String) {
        var secretFromQuery = expectedSecret
        if let comps = URLComponents(string: path), let items = comps.queryItems {
            if let sec = items.first(where: { $0.name == "secret" })?.value {
                secretFromQuery = sec
            }
        }

        let appDeepLink = "genplayer://pair?ip=\(localIP)&port=\(port)&secret=\(secretFromQuery)&type=\(serverType.rawValue)"
        let html = htmlLandingPage(deepLink: appDeepLink, secret: secretFromQuery)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(html)
        """
        send(string: response)
    }

    private func handleApiPair(bodyString: String) {
        guard let data = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendJsonError("Invalid JSON body", code: 400)
            return
        }

        let secret = (json["secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard secret == expectedSecret else {
            sendJsonError("Invalid pairing secret", code: 403)
            return
        }

        let accessToken = (json["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refreshToken = (json["refreshToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = (json["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !accessToken.isEmpty else {
            sendJsonError("Access token is required", code: 400)
            return
        }

        let result = TVLocalPairingServer.PairingResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            displayName: displayName,
            serverType: serverType
        )

        let successJson = "{\"success\":true,\"message\":\"Paired successfully\"}"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(successJson.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(successJson)
        """
        send(string: response)
        onSuccess?(result)
    }

    private func sendOptionsResponse() {
        let response = """
        HTTP/1.1 204 No Content\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Connection: close\r
        \r
        """
        send(string: response)
    }

    private func sendJsonError(_ message: String, code: Int) {
        let json = "{\"error\":\"\(message)\"}"
        let statusText = code == 403 ? "Forbidden" : "Bad Request"
        let response = """
        HTTP/1.1 \(code) \(statusText)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(json.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(json)
        """
        send(string: response)
    }

    private func send(string: String) {
        guard let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = Darwin.write(clientSocket, base, data.count)
        }
    }

    private func htmlLandingPage(deepLink: String, secret: String) -> String {
        let typeName = serverType.displayName
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
            <title>GenPlayer Apple TV Authorization</title>
            <style>
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background-color: #0b0c10;
                    color: #ffffff;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    min-height: 100vh;
                    padding: 24px;
                    text-align: center;
                }
                .card {
                    background: #1f2833;
                    border: 1px solid #333d4b;
                    border-radius: 20px;
                    padding: 32px 24px;
                    max-width: 440px;
                    width: 100%;
                    box-shadow: 0 12px 32px rgba(0,0,0,0.6);
                }
                .icon {
                    width: 72px;
                    height: 72px;
                    margin-bottom: 20px;
                    border-radius: 18px;
                    background: #2b3848;
                    display: inline-flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 36px;
                }
                h1 { font-size: 22px; font-weight: 700; margin-bottom: 12px; }
                p { font-size: 15px; color: #a4b3c6; line-height: 1.5; margin-bottom: 24px; }
                .btn {
                    display: block;
                    width: 100%;
                    padding: 16px;
                    border-radius: 14px;
                    font-size: 17px;
                    font-weight: 600;
                    text-decoration: none;
                    text-align: center;
                    background: #007aff;
                    color: #ffffff;
                    border: none;
                    cursor: pointer;
                    margin-bottom: 16px;
                    transition: transform 0.1s ease, background-color 0.2s;
                }
                .btn:active { transform: scale(0.98); background: #0063d1; }
                .hint {
                    font-size: 13px;
                    color: #718096;
                    line-height: 1.4;
                    margin-top: 12px;
                }
                .badge {
                    display: inline-block;
                    padding: 4px 10px;
                    background: rgba(255,255,255,0.1);
                    border-radius: 8px;
                    font-size: 13px;
                    font-family: monospace;
                    margin-bottom: 16px;
                }
            </style>
        </head>
        <body>
            <div class="card">
                <div class="icon">📺</div>
                <h1>Apple TV Authorization</h1>
                <p>Sign in to <strong>\(typeName)</strong> on your phone to connect your Apple TV.</p>
                <div class="badge">Secret: \(secret)</div>
                <a href="\(deepLink)" class="btn" id="openBtn">Open GenPlayer to Sign In</a>
                <div class="hint">
                    Tap the button above to launch GenPlayer and sign in with official \(typeName) authentication.
                </div>
            </div>
            <script>
                // Auto trigger deep link on page load
                setTimeout(function() {
                    window.location.href = "\(deepLink)";
                }, 200);
            </script>
        </body>
        </html>
        """
    }
}
#endif
