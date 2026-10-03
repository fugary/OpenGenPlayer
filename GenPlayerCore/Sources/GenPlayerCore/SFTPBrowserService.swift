import Foundation
import Darwin
import GenPlayerSSH2

private typealias LibSSH2SessionRef = OpaquePointer
private typealias LibSSH2SFTPRef = OpaquePointer
private typealias LibSSH2SFTPHandleRef = OpaquePointer

private typealias LibSSH2SFTPAttributes = LIBSSH2_SFTP_ATTRIBUTES

private enum LibSSH2Interop {
    static let attrSize: UInt = 0x00000001
    static let attrPermissions: UInt = 0x00000004
    static let attrAccessModifyTime: UInt = 0x00000008

    static let fileTypeMask: UInt = 0o170000
    static let directoryFlag: UInt = 0o040000

    static let fileOpenRead: UInt = 0x00000001
    static let openFile: Int32 = 0
    static let openDirectory: Int32 = 1
    static let statFile: Int32 = 0

    static let errorEAgain: Int32 = -37
    static let errorAuthenticationFailed: Int32 = -18

    static let disconnectByApplication: Int32 = 11

    private static let initLock = NSLock()
    private static var didInitialize = false

    static func initializeIfNeeded() throws {
        initLock.lock()
        defer { initLock.unlock() }

        if didInitialize {
            return
        }

        let result = GPSSH2Initialize()
        guard result == 0 else {
            throw SFTPBrowserError.initializationFailed(code: result)
        }

        didInitialize = true
    }
}

public enum SFTPBrowserError: LocalizedError {
    case initializationFailed(code: Int32)
    case invalidAddress
    case missingUsername
    case socketConnectionFailed(message: String)
    case sessionCreationFailed
    case handshakeFailed(code: Int32)
    case authenticationFailed
    case sftpInitializationFailed(code: Int32)
    case directoryOpenFailed(path: String, code: Int32)
    case fileOpenFailed(path: String, code: Int32)
    case readDirectoryFailed(path: String, code: Int32)
    case readFileFailed(path: String, code: Int32)
    case createTempDirectoryFailed
    case createDestinationFailed

    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return NSLocalizedString("Failed to initialize SFTP runtime.", comment: "")
        case .invalidAddress:
            return NSLocalizedString("Invalid SFTP server address.", comment: "")
        case .missingUsername:
            return NSLocalizedString("Please provide an SFTP username.", comment: "")
        case .socketConnectionFailed(let message):
            return message
        case .sessionCreationFailed:
            return NSLocalizedString("Failed to create SFTP session.", comment: "")
        case .handshakeFailed:
            return NSLocalizedString("Failed to start SFTP session handshake.", comment: "")
        case .authenticationFailed:
            return NSLocalizedString("SFTP authentication failed. Please check username and password.", comment: "")
        case .sftpInitializationFailed:
            return NSLocalizedString("Failed to initialize SFTP subsystem.", comment: "")
        case .directoryOpenFailed:
            return NSLocalizedString("Unable to open remote directory.", comment: "")
        case .fileOpenFailed:
            return NSLocalizedString("Unable to open remote file.", comment: "")
        case .readDirectoryFailed:
            return NSLocalizedString("Failed to read remote directory.", comment: "")
        case .readFileFailed:
            return NSLocalizedString("Failed to read remote file.", comment: "")
        case .createTempDirectoryFailed:
            return NSLocalizedString("Failed to prepare temporary download folder.", comment: "")
        case .createDestinationFailed:
            return NSLocalizedString("Failed to create local temporary file.", comment: "")
        }
    }
}

public final class SFTPBrowserService: @unchecked Sendable {
    public static let shared = SFTPBrowserService()

    private init() {}

    public func testConnection(server: ServerConfig) async throws {
        _ = try await listFiles(server: server, at: "/")
    }

    public func listFiles(server: ServerConfig, at path: String) async throws -> [VideoFile] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let files = try self.listFilesSync(server: server, at: path)
                    continuation.resume(returning: files)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func downloadFile(
        server: ServerConfig,
        at path: String,
        progress: ((Int64, Int64) -> Void)?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try self.downloadFileSync(server: server, at: path, progress: progress)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func listFilesSync(server: ServerConfig, at path: String) throws -> [VideoFile] {
        let endpoint = try parsedEndpoint(for: server)
        let remotePath = normalizedAbsolutePath(requestedPath: path, basePath: endpoint.basePath)
        let session = try SFTPSession(server: server, endpoint: endpoint)
        return try session.listDirectory(at: remotePath)
    }

    private func downloadFileSync(
        server: ServerConfig,
        at path: String,
        progress: ((Int64, Int64) -> Void)?
    ) throws -> URL {
        let endpoint = try parsedEndpoint(for: server)
        let remotePath = normalizedAbsolutePath(requestedPath: path, basePath: endpoint.basePath)
        let session = try SFTPSession(server: server, endpoint: endpoint)
        return try session.downloadFile(at: remotePath, progress: progress)
    }

    #if os(macOS) || os(iOS) || os(tvOS)
    func audioRangeSource(server: ServerConfig, path: String) -> any AudioRangeSource {
        BlockingAudioRangeSource {
            let endpoint = try self.parsedEndpoint(for: server)
            let remotePath = self.normalizedAbsolutePath(requestedPath: path, basePath: endpoint.basePath)
            let session = try SFTPSession(server: server, endpoint: endpoint, boundedConnect: true)
            return try session.audioFile(at: remotePath)
        }
    }
    #endif

    private func parsedEndpoint(for server: ServerConfig) throws -> (host: String, runtimeHost: String, port: Int, basePath: String) {
        let defaultPort = ServerConfig.defaultPort(for: .sftp, useSSL: false)
        let trimmedAddress = server.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            throw SFTPBrowserError.invalidAddress
        }

        let host: String
        let port: Int
        let basePath: String

        if trimmedAddress.contains("://"),
           let components = URLComponents(string: trimmedAddress),
           let parsedHost = components.host,
           !parsedHost.isEmpty {
            host = parsedHost
            port = server.port ?? components.port ?? defaultPort
            basePath = components.path == "/" ? "" : components.path
        } else {
            let hostPart = trimmedAddress.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmedAddress
            guard !hostPart.isEmpty else {
                throw SFTPBrowserError.invalidAddress
            }
            host = hostPart
            port = server.port ?? defaultPort
            if let slashIndex = trimmedAddress.firstIndex(of: "/") {
                basePath = String(trimmedAddress[slashIndex...])
            } else {
                basePath = ""
            }
        }

        let runtimeHost = RuntimeNetworkAddressResolver.runtimeAddress(from: host)
        return (host, runtimeHost, port, basePath)
    }

    private func normalizedAbsolutePath(requestedPath: String, basePath: String) -> String {
        let resolvedBasePath: String = {
            let trimmedBase = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBase.isEmpty {
                return "/"
            }
            return trimmedBase.hasPrefix("/") ? trimmedBase : "/\(trimmedBase)"
        }()

        let resolvedRequestedPath: String = {
            let trimmedPath = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.isEmpty {
                return "/"
            }
            return trimmedPath.hasPrefix("/") ? trimmedPath : "/\(trimmedPath)"
        }()

        if resolvedRequestedPath == "/" {
            return resolvedBasePath
        }

        if resolvedBasePath == "/" ||
            resolvedRequestedPath == resolvedBasePath ||
            resolvedRequestedPath.hasPrefix("\(resolvedBasePath)/") {
            return resolvedRequestedPath
        }

        let trimmedBase = resolvedBasePath.hasSuffix("/") ? String(resolvedBasePath.dropLast()) : resolvedBasePath
        return "\(trimmedBase)\(resolvedRequestedPath)"
    }
}

private final class SFTPSession {
    private let server: ServerConfig
    private let endpoint: (host: String, runtimeHost: String, port: Int, basePath: String)
    private let username: String
    private let password: String

    private let socketFD: Int32
    private let sessionRef: LibSSH2SessionRef
    private let sftpRef: LibSSH2SFTPRef

    init(server: ServerConfig, endpoint: (host: String, runtimeHost: String, port: Int, basePath: String), boundedConnect: Bool = false) throws {
        try LibSSH2Interop.initializeIfNeeded()

        guard let username = server.username?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty else {
            throw SFTPBrowserError.missingUsername
        }

        let resolvedPassword = server.passwordSecret ?? ""

        self.server = server
        self.endpoint = endpoint
        self.username = username
        self.password = resolvedPassword

        let socketFD = try Self.openSocket(host: endpoint.runtimeHost, port: endpoint.port, boundedConnect: boundedConnect)
        self.socketFD = socketFD

        guard let sessionRef = libssh2_session_init_ex(nil, nil, nil, nil) else {
            close(socketFD)
            throw SFTPBrowserError.sessionCreationFailed
        }
        self.sessionRef = sessionRef

        libssh2_session_set_blocking(sessionRef, 1)
        libssh2_session_set_timeout(sessionRef, 15_000)

        let handshakeResult = libssh2_session_handshake(sessionRef, socketFD)
        guard handshakeResult == 0 else {
            _ = libssh2_session_free(sessionRef)
            close(socketFD)
            throw SFTPBrowserError.handshakeFailed(code: handshakeResult)
        }

        let authResult = username.withCString { usernamePointer in
            resolvedPassword.withCString { passwordPointer in
                libssh2_userauth_password_ex(
                    sessionRef,
                    usernamePointer,
                    UInt32(username.utf8.count),
                    passwordPointer,
                    UInt32(resolvedPassword.utf8.count),
                    nil
                )
            }
        }

        guard authResult == 0 else {
            let lastError = libssh2_session_last_errno(sessionRef)
            _ = libssh2_session_disconnect_ex(sessionRef, LibSSH2Interop.disconnectByApplication, "Authentication failed", "")
            _ = libssh2_session_free(sessionRef)
            close(socketFD)
            if authResult == LibSSH2Interop.errorAuthenticationFailed || lastError == LibSSH2Interop.errorAuthenticationFailed {
                throw SFTPBrowserError.authenticationFailed
            }
            throw SFTPBrowserError.handshakeFailed(code: authResult)
        }

        guard let sftpRef = libssh2_sftp_init(sessionRef) else {
            let lastError = libssh2_session_last_errno(sessionRef)
            _ = libssh2_session_disconnect_ex(sessionRef, LibSSH2Interop.disconnectByApplication, "SFTP init failed", "")
            _ = libssh2_session_free(sessionRef)
            close(socketFD)
            throw SFTPBrowserError.sftpInitializationFailed(code: lastError)
        }
        self.sftpRef = sftpRef
    }

    deinit {
        _ = libssh2_sftp_shutdown(sftpRef)
        _ = libssh2_session_disconnect_ex(sessionRef, LibSSH2Interop.disconnectByApplication, "Normal Shutdown", "")
        _ = libssh2_session_free(sessionRef)
        close(socketFD)
    }

    func listDirectory(at path: String) throws -> [VideoFile] {
        let remotePath = normalizedRemotePath(path)

        guard let handle = openDirectoryHandle(path: remotePath) else {
            throw SFTPBrowserError.directoryOpenFailed(path: remotePath, code: libssh2_session_last_errno(sessionRef))
        }
        defer { _ = libssh2_sftp_close_handle(handle) }

        var files: [VideoFile] = []
        var filenameBuffer = [CChar](repeating: 0, count: 4096)
        var longEntryBuffer = [CChar](repeating: 0, count: 4096)

        while true {
            var attributes = LibSSH2SFTPAttributes(flags: 0, filesize: 0, uid: 0, gid: 0, permissions: 0, atime: 0, mtime: 0)
            let result = libssh2_sftp_readdir_ex(
                handle,
                &filenameBuffer,
                filenameBuffer.count,
                &longEntryBuffer,
                longEntryBuffer.count,
                &attributes
            )

            if result > 0 {
                let name = String(cString: filenameBuffer)
                if name == "." || name == ".." {
                    continue
                }

                let remoteChildPath = joinRemotePath(base: remotePath, name: name)
                let fileType = fileType(forName: name, attributes: attributes, longEntry: String(cString: longEntryBuffer))
                let playbackURL = buildPlaybackURL(path: remoteChildPath)

                var file = VideoFile(
                    name: name,
                    url: playbackURL,
                    type: fileType,
                    size: attributes.flags & LibSSH2Interop.attrSize != 0 ? Int64(clamping: attributes.filesize) : 0,
                    date: attributes.flags & LibSSH2Interop.attrAccessModifyTime != 0 ? Date(timeIntervalSince1970: TimeInterval(attributes.mtime)) : Date(),
                    duration: nil
                )
                file.isRemote = true
                file.serverType = .sftp
                file.jellyfinServerId = server.id.uuidString
                file.serverPath = remoteChildPath
                files.append(file)
            } else if result == 0 {
                break
            } else {
                throw SFTPBrowserError.readDirectoryFailed(path: remotePath, code: Int32(result))
            }
        }

        return files.sorted { lhs, rhs in
            if lhs.type == .folder && rhs.type != .folder { return true }
            if lhs.type != .folder && rhs.type == .folder { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func downloadFile(at path: String, progress: ((Int64, Int64) -> Void)?) throws -> URL {
        let remotePath = normalizedRemotePath(path)
        let totalSize = fileSize(at: remotePath)

        guard let handle = openFileHandle(path: remotePath) else {
            throw SFTPBrowserError.fileOpenFailed(path: remotePath, code: libssh2_session_last_errno(sessionRef))
        }
        defer { _ = libssh2_sftp_close_handle(handle) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            throw SFTPBrowserError.createTempDirectoryFailed
        }

        let fileName = URL(fileURLWithPath: remotePath).lastPathComponent
        let destinationURL = tempDir.appendingPathComponent(fileName)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil),
              let outputStream = OutputStream(url: destinationURL, append: false) else {
            throw SFTPBrowserError.createDestinationFailed
        }

        outputStream.open()
        defer { outputStream.close() }

        var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        var downloadedBytes: Int64 = 0

        while true {
            let readCount = readBuffer.withUnsafeMutableBytes { bytes in
                libssh2_sftp_read(handle, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
            }
            if readCount > 0 {
                var written = 0
                while written < readCount {
                    let chunk = readBuffer.withUnsafeBytes { rawBuffer -> Int in
                        guard let baseAddress = rawBuffer.baseAddress else {
                            return -1
                        }
                        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self).advanced(by: written)
                        return outputStream.write(pointer, maxLength: readCount - written)
                    }
                    if chunk <= 0 {
                        throw SFTPBrowserError.createDestinationFailed
                    }
                    written += chunk
                }

                downloadedBytes += Int64(readCount)
                progress?(downloadedBytes, totalSize)
            } else if readCount == 0 {
                break
            } else {
                throw SFTPBrowserError.readFileFailed(path: remotePath, code: Int32(readCount))
            }
        }

        return destinationURL
    }

    private func fileSize(at path: String) -> Int64 {
        var attributes = LibSSH2SFTPAttributes(flags: 0, filesize: 0, uid: 0, gid: 0, permissions: 0, atime: 0, mtime: 0)
        let result = path.withCString { pathPointer in
            libssh2_sftp_stat_ex(sftpRef, pathPointer, UInt32(strlen(pathPointer)), LibSSH2Interop.statFile, &attributes)
        }

        guard result == 0, attributes.flags & LibSSH2Interop.attrSize != 0 else {
            return 0
        }
        return Int64(clamping: attributes.filesize)
    }

    private func fileType(forName name: String, attributes: LibSSH2SFTPAttributes, longEntry: String) -> VideoFile.FileType {
        if attributes.flags & LibSSH2Interop.attrPermissions != 0,
           (attributes.permissions & LibSSH2Interop.fileTypeMask) == LibSSH2Interop.directoryFlag {
            return .folder
        }

        if longEntry.first == "d" {
            return .folder
        }

        return VideoFile.FileType.determineType(from: URL(fileURLWithPath: name))
    }

    private func openDirectoryHandle(path: String) -> LibSSH2SFTPHandleRef? {
        path.withCString { pathPointer in
            libssh2_sftp_open_ex(
                sftpRef,
                pathPointer,
                UInt32(strlen(pathPointer)),
                0,
                0,
                LibSSH2Interop.openDirectory
            )
        }
    }

    private func openFileHandle(path: String) -> LibSSH2SFTPHandleRef? {
        path.withCString { pathPointer in
            libssh2_sftp_open_ex(
                sftpRef,
                pathPointer,
                UInt32(strlen(pathPointer)),
                LibSSH2Interop.fileOpenRead,
                0,
                LibSSH2Interop.openFile
            )
        }
    }

    private func buildPlaybackURL(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "sftp"
        components.host = endpoint.host
        components.port = endpoint.port
        components.path = path

        if !username.isEmpty {
            components.user = username
        }
        if !password.isEmpty {
            components.password = password
        }

        return components.url ?? URL(fileURLWithPath: path)
    }

    private func normalizedRemotePath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return "/"
        }
        if !path.hasPrefix("/") {
            path = "/\(path)"
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private func joinRemotePath(base: String, name: String) -> String {
        let normalizedBase = normalizedRemotePath(base)
        if normalizedBase == "/" {
            return "/\(name)"
        }
        return "\(normalizedBase)/\(name)"
    }

    private static func openSocket(host: String, port: Int, boundedConnect: Bool) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = String(port).withCString { portCString in
            host.withCString { hostCString in
                getaddrinfo(hostCString, portCString, &hints, &resultPointer)
            }
        }

        guard status == 0, let firstResult = resultPointer else {
            let message = String(format: NSLocalizedString("Unable to connect to %@:%d.", comment: ""), host, port)
            throw SFTPBrowserError.socketConnectionFailed(message: message)
        }

        defer { freeaddrinfo(resultPointer) }

        var pointer: UnsafeMutablePointer<addrinfo>? = firstResult
        var lastErrno: Int32 = 0

        while let info = pointer {
            let socketFD = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if socketFD >= 0 {
                var noSigPipe: Int32 = 1
                setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

                var timeout = timeval(tv_sec: 15, tv_usec: 0)
                setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                let flags = fcntl(socketFD, F_GETFL, 0)
                if boundedConnect { _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) }
                var connected = connect(socketFD, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
                if boundedConnect, !connected, errno == EINPROGRESS {
                    var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, 15_000) > 0 {
                        var failure: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                        connected = getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0
                    }
                }
                if boundedConnect { _ = fcntl(socketFD, F_SETFL, flags) }
                if connected {
                    return socketFD
                }

                lastErrno = errno
                close(socketFD)
            }

            pointer = info.pointee.ai_next
        }

        let message = String(format: NSLocalizedString("Unable to connect to %@:%d.", comment: ""), host, port)
        if lastErrno != 0 {
            throw SFTPBrowserError.socketConnectionFailed(message: "\(message) (\(String(cString: strerror(lastErrno))))")
        }
        throw SFTPBrowserError.socketConnectionFailed(message: message)
    }
}

#if os(macOS) || os(iOS) || os(tvOS)
private extension SFTPSession {
    func audioFile(at path: String) throws -> BlockingAudioFile {
        guard let handle = openFileHandle(path: normalizedRemotePath(path)) else { throw AudioRangeFailure.invalidResponse }
        return SFTPAudioFile(session: self, handle: handle)
    }
}

private final class SFTPAudioFile: BlockingAudioFile {
    private let session: SFTPSession
    private let handle: LibSSH2SFTPHandleRef
    init(session: SFTPSession, handle: LibSSH2SFTPHandleRef) { self.session = session; self.handle = handle }
    deinit { _ = libssh2_sftp_close_handle(handle) }
    func metadata() throws -> AudioFileVersion {
        var attributes = LibSSH2SFTPAttributes(flags: 0, filesize: 0, uid: 0, gid: 0, permissions: 0, atime: 0, mtime: 0)
        guard libssh2_sftp_fstat_ex(handle, &attributes, 0) == 0,
              attributes.flags & LibSSH2Interop.attrSize != 0,
              attributes.flags & LibSSH2Interop.attrAccessModifyTime != 0,
              attributes.filesize > 0 else { throw AudioRangeFailure.unsupported }
        return .init(size: attributes.filesize, stamp: String(attributes.mtime))
    }
    func read(offset: UInt64, count: Int, cancellation: AudioReadCancellation) throws -> Data {
        libssh2_sftp_seek64(handle, offset)
        var data = Data()
        while data.count < count {
            try cancellation.check()
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, count - data.count))
            let read = buffer.withUnsafeMutableBytes { bytes in
                libssh2_sftp_read(handle, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
            }
            guard read > 0, read <= buffer.count else { throw AudioRangeFailure.invalidResponse }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }
}
#endif
