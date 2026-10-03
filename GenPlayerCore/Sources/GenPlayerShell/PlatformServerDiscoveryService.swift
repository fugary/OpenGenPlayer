import Foundation
import Network
import GenPlayerCore

final class PlatformServerDiscoveryService: NSObject, ObservableObject {
    static let shared = PlatformServerDiscoveryService()

    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var isSearching = false

    private var browsers: [NetServiceBrowser] = []
    private var activeBrowsers: Set<ObjectIdentifier> = []
    private var resolvingServices: [NetService] = []
    private var discoveryTimeoutTask: DispatchWorkItem?
    private var probedHosts: Set<String> = []
    private var mediaProbeTasks: [String: Task<Void, Never>] = [:]
    private lazy var probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 4.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private struct DiscoveryTarget {
        let serviceType: String
        let serverType: ServerConfig.ServerType?
        let useSSL: Bool
        let inferFromServiceMetadata: Bool
    }

    private struct MediaProbeTarget {
        let type: ServerConfig.ServerType
        let useSSL: Bool
        let port: Int
        let path: String
    }

    private struct PortProbeTarget {
        let type: ServerConfig.ServerType
        let port: Int
    }

    private let discoveryTargets: [DiscoveryTarget] = [
        DiscoveryTarget(serviceType: "_smb._tcp.", serverType: .smb, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_jellyfin._tcp.", serverType: .jellyfin, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_jellyfin-server._tcp.", serverType: .jellyfin, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_emby-server._tcp.", serverType: .emby, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_embyserver._tcp.", serverType: .emby, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_plexmediasvr._tcp.", serverType: .plex, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_plexmediaserver._tcp.", serverType: .plex, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_plex._tcp.", serverType: .plex, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_webdav._tcp.", serverType: .webdav, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_webdavs._tcp.", serverType: .webdav, useSSL: true, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_ftp._tcp.", serverType: .ftp, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_sftp._tcp.", serverType: .sftp, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_sftp-ssh._tcp.", serverType: .sftp, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_ssh._tcp.", serverType: .sftp, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_nfs._tcp.", serverType: .nfs, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_nfs._udp.", serverType: .nfs, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_mountd._tcp.", serverType: .nfs, useSSL: false, inferFromServiceMetadata: false),
        DiscoveryTarget(serviceType: "_http._tcp.", serverType: nil, useSSL: false, inferFromServiceMetadata: true),
        DiscoveryTarget(serviceType: "_https._tcp.", serverType: nil, useSSL: true, inferFromServiceMetadata: true),
        DiscoveryTarget(serviceType: "_alist._tcp.", serverType: .alist, useSSL: false, inferFromServiceMetadata: false)
    ]

    private let mediaProbeTargets: [MediaProbeTarget] = [
        MediaProbeTarget(type: .jellyfin, useSSL: false, port: 8096, path: "/System/Info/Public"),
        MediaProbeTarget(type: .jellyfin, useSSL: true, port: 8920, path: "/System/Info/Public"),
        MediaProbeTarget(type: .jellyfin, useSSL: true, port: 443, path: "/System/Info/Public"),
        MediaProbeTarget(type: .jellyfin, useSSL: true, port: 443, path: "/jellyfin/System/Info/Public"),
        MediaProbeTarget(type: .emby, useSSL: false, port: 8096, path: "/System/Info/Public"),
        MediaProbeTarget(type: .emby, useSSL: true, port: 8920, path: "/System/Info/Public"),
        MediaProbeTarget(type: .emby, useSSL: true, port: 443, path: "/System/Info/Public"),
        MediaProbeTarget(type: .plex, useSSL: false, port: 32400, path: "/identity"),
        MediaProbeTarget(type: .plex, useSSL: true, port: 32400, path: "/identity"),
        MediaProbeTarget(type: .plex, useSSL: true, port: 443, path: "/identity"),
        MediaProbeTarget(type: .alist, useSSL: false, port: 5244, path: "/api/public/settings"),
        MediaProbeTarget(type: .alist, useSSL: true, port: 5244, path: "/api/public/settings"),
        MediaProbeTarget(type: .alist, useSSL: true, port: 443, path: "/api/public/settings")
    ]

    private let streamProbeTargets: [PortProbeTarget] = [
        PortProbeTarget(type: .ftp, port: 21),
        PortProbeTarget(type: .sftp, port: 22),
        PortProbeTarget(type: .nfs, port: 2049)
    ]

    struct DiscoveredServer: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let hostName: String
        let port: Int
        let type: ServerConfig.ServerType
        let useSSL: Bool

        var address: String {
            hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        }

        static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
            lhs.hostName == rhs.hostName &&
            lhs.port == rhs.port &&
            lhs.type == rhs.type &&
            lhs.useSSL == rhs.useSSL
        }
    }

    func startDiscovery() {
        stopDiscovery()

        discoveredServers.removeAll()
        isSearching = true

        let timeoutTask = DispatchWorkItem { [weak self] in
            self?.stopDiscovery()
        }
        discoveryTimeoutTask = timeoutTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: timeoutTask)

        browsers = discoveryTargets.map { target in
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: target.serviceType, inDomain: "local.")
            return browser
        }
        activeBrowsers = Set(browsers.map { ObjectIdentifier($0) })
    }

    func stopDiscovery() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        activeBrowsers.removeAll()
        resolvingServices.removeAll()
        mediaProbeTasks.values.forEach { $0.cancel() }
        mediaProbeTasks.removeAll()
        probedHosts.removeAll()
        isSearching = false
    }

    func createServerConfig(from discoveredServer: DiscoveredServer) -> ServerConfig {
        ServerConfig(
            name: discoveredServer.name,
            address: discoveredServer.address,
            port: discoveredServer.port,
            useSSL: discoveredServer.useSSL,
            type: discoveredServer.type,
            username: nil,
            passwordSecret: nil,
            workgroup: nil
        )
    }

    private func target(for serviceType: String) -> DiscoveryTarget? {
        let normalized = normalizeServiceType(serviceType)
        return discoveryTargets.first { normalizeServiceType($0.serviceType) == normalized }
    }

    private func normalizeServiceType(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }

    private func inferredType(for service: NetService, target: DiscoveryTarget) -> ServerConfig.ServerType? {
        if let explicitType = target.serverType {
            return explicitType
        }
        guard target.inferFromServiceMetadata else { return nil }

        var metadata = "\(service.name) \(service.type)".lowercased()
        if let txtRecordData = service.txtRecordData() {
            let txtRecord = NetService.dictionary(fromTXTRecord: txtRecordData)
            let txtPairs = txtRecord.map { key, value in
                let textValue = String(data: value, encoding: .utf8) ?? ""
                return "\(key.lowercased())=\(textValue.lowercased())"
            }
            metadata += " " + txtPairs.joined(separator: " ")
        }

        if metadata.contains("jellyfin") { return .jellyfin }
        if metadata.contains("emby") { return .emby }
        if metadata.contains("plex") { return .plex }
        if metadata.contains("webdav") { return .webdav }
        if metadata.contains("alist") { return .alist }
        return nil
    }

    private func resolvedUseSSL(for service: NetService, target: DiscoveryTarget) -> Bool {
        if target.serverType != nil {
            return target.useSSL
        }
        return target.useSSL || service.type.lowercased().contains("_https.")
    }

    private func typeSortRank(_ type: ServerConfig.ServerType) -> Int {
        switch type {
        case .smb: return 0
        case .webdav: return 1
        case .ftp: return 2
        case .sftp: return 3
        case .nfs: return 4
        case .jellyfin: return 5
        case .emby: return 6
        case .plex: return 7
        case .alist: return 8
        case .pan115, .onedrive, .googledrive: return 9
        case .iptv, .vod: return 10
        }
    }

    private func markBrowserFinished(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async {
            self.activeBrowsers.remove(ObjectIdentifier(browser))
            if self.activeBrowsers.isEmpty {
                self.isSearching = false
            }
        }
    }

    private func resolvedHostName(for service: NetService) -> String? {
        if let hostName = service.hostName, !hostName.isEmpty {
            return hostName
        }

        guard let addresses = service.addresses else { return nil }
        for address in addresses {
            if let ip = ipAddress(from: address), !ip.isEmpty {
                return ip
            }
        }
        return nil
    }

    private func ipAddress(from addressData: Data) -> String? {
        addressData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                return nil
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                base,
                socklen_t(addressData.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { return nil }
            return String(cString: hostBuffer)
        }
    }

    private func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private func displayName(for type: ServerConfig.ServerType) -> String {
        type.displayName
    }

    private func appendDiscovered(_ server: DiscoveredServer) {
        DispatchQueue.main.async {
            if !self.discoveredServers.contains(where: { $0 == server }) {
                self.discoveredServers.append(server)
                self.discoveredServers.sort {
                    let lhsRank = self.typeSortRank($0.type)
                    let rhsRank = self.typeSortRank($1.type)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    private func triggerMediaProbe(for host: String, seedName: String?) {
        let normalizedHost = normalizedHost(host)
        guard !normalizedHost.isEmpty else { return }
        guard !probedHosts.contains(normalizedHost) else { return }
        probedHosts.insert(normalizedHost)

        mediaProbeTasks[normalizedHost]?.cancel()
        mediaProbeTasks[normalizedHost] = Task { [weak self] in
            guard let self else { return }
            var resolvedTypes: Set<ServerConfig.ServerType> = []

            for target in mediaProbeTargets {
                if Task.isCancelled { return }
                if resolvedTypes.contains(target.type) { continue }
                let reachable = await probeMediaService(host: normalizedHost, target: target)
                if reachable {
                    let cleanedSeedName = seedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let serverName = cleanedSeedName.isEmpty ? displayName(for: target.type) : cleanedSeedName
                    appendDiscovered(
                        DiscoveredServer(
                            name: serverName,
                            hostName: normalizedHost,
                            port: target.port,
                            type: target.type,
                            useSSL: target.useSSL
                        )
                    )
                    resolvedTypes.insert(target.type)
                }
            }

            for target in streamProbeTargets {
                if Task.isCancelled { return }
                if resolvedTypes.contains(target.type) { continue }

                let reachable = await probeTCPService(host: normalizedHost, port: target.port)
                if reachable {
                    let cleanedSeedName = seedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let serverName = cleanedSeedName.isEmpty ? displayName(for: target.type) : cleanedSeedName
                    appendDiscovered(
                        DiscoveredServer(
                            name: serverName,
                            hostName: normalizedHost,
                            port: target.port,
                            type: target.type,
                            useSSL: false
                        )
                    )
                    resolvedTypes.insert(target.type)
                }
            }
        }
    }

    private func probeMediaService(host: String, target: MediaProbeTarget) async -> Bool {
        let scheme = target.useSSL ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(target.port)\(target.path)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5

        do {
            let (data, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }

            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { partial, item in
                let key = "\(item.key)".lowercased()
                let value = "\(item.value)".lowercased()
                partial[key] = value
            }
            let statusCode = http.statusCode

            switch target.type {
            case .plex:
                if (200...299).contains(statusCode) {
                    return body.contains("mediacontainer")
                        || body.contains("machineidentifier")
                        || headers.keys.contains(where: { $0.hasPrefix("x-plex-") })
                }
                if statusCode == 401 || statusCode == 403 {
                    return headers.keys.contains(where: { $0.hasPrefix("x-plex-") })
                }
                return false
            case .jellyfin:
                if (200...299).contains(statusCode) {
                    return body.contains("jellyfin")
                        || body.contains("servername")
                        || headers["server"]?.contains("jellyfin") == true
                }
                if statusCode == 401 || statusCode == 403 {
                    return headers["server"]?.contains("jellyfin") == true
                }
                return false
            case .emby:
                if (200...299).contains(statusCode) {
                    return body.contains("emby")
                        || headers["server"]?.contains("emby") == true
                }
                if statusCode == 401 || statusCode == 403 {
                    return headers["server"]?.contains("emby") == true
                }
                return false
            case .alist:
                if (200...299).contains(statusCode) {
                    return body.contains("alist")
                }
                return false
            default:
                return false
            }
        } catch {
            return false
        }
    }

    private func probeTCPService(host: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var finished = false

            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                finish(false)
            }
        }
    }
}

extension PlatformServerDiscoveryService: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let target = target(for: service.type),
           let serverType = inferredType(for: service, target: target) {
            let useSSL = resolvedUseSSL(for: service, target: target)
            if let index = discoveredServers.firstIndex(where: { $0.name == service.name && $0.type == serverType && $0.useSSL == useSSL }) {
                DispatchQueue.main.async {
                    self.discoveredServers.remove(at: index)
                }
            }
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        markBrowserFinished(browser)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        markBrowserFinished(browser)
    }
}

extension PlatformServerDiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = resolvedHostName(for: sender) else { return }
        guard let target = target(for: sender.type) else { return }
        guard let serverType = inferredType(for: sender, target: target) else { return }

        let server = DiscoveredServer(
            name: sender.name,
            hostName: normalizedHost(hostName),
            port: sender.port,
            type: serverType,
            useSSL: resolvedUseSSL(for: sender, target: target)
        )
        appendDiscovered(server)
        triggerMediaProbe(for: server.hostName, seedName: sender.name)

        if let index = resolvingServices.firstIndex(of: sender) {
            resolvingServices.remove(at: index)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        if let index = resolvingServices.firstIndex(of: sender) {
            resolvingServices.remove(at: index)
        }
    }
}

extension PlatformServerDiscoveryService: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
