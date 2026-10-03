import Foundation

/// Only routes known authorization codes. Scanning never opens an arbitrary URL.
enum TVAuthorizationQRCode: Equatable {
    struct Pairing: Equatable {
        let ip: String
        let port: Int
        let secret: String
        let provider: String
    }

    case pairing(Pairing)
    case plex(URL)
    case pan115

    static func parse(_ value: String) -> Self? {
        guard value.utf8.count <= 2048,
              let url = URLComponents(string: value),
              url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }

        if (scheme == "https" || scheme == "http"),
           host == "115.com" || host.hasSuffix(".115.com") {
            return .pan115
        }

        // Query duplicates are ambiguous; never silently pick one destination or secret.
        let items = url.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        if scheme == "https", host == "plex.tv", url.port == nil || url.port == 443,
           url.path == "/link" || url.path == "/link/", url.fragment == nil,
           let pin = query["pin"], (4...32).contains(pin.count), isASCIIAlphanumeric(pin) {
            var destination = URLComponents(string: "https://plex.tv/link/")!
            destination.queryItems = [URLQueryItem(name: "pin", value: pin)]
            return destination.url.map(Self.plex)
        }

        let ip: String
        let port: Int
        if scheme == "http", url.path == "/pair", let httpPort = url.port {
            ip = host
            port = httpPort
        } else if scheme == "genplayer", host == "pair", url.path.isEmpty, url.port == nil,
                  let address = query["ip"], let portValue = query["port"], let deepLinkPort = Int(portValue) {
            ip = address
            port = deepLinkPort
        } else {
            return nil
        }

        guard url.fragment == nil, isLocalIPv4(ip), (1...65535).contains(port),
              let secret = query["secret"], secret.count == 6, isASCIIAlphanumeric(secret),
              let provider = query["type"], ["googledrive", "onedrive"].contains(provider) else { return nil }
        return .pairing(Pairing(ip: ip, port: port, secret: secret, provider: provider))
    }

    private static func isASCIIAlphanumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private static func isLocalIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> UInt8? in
            guard let byte = UInt8(part), String(byte) == part else { return nil }
            return byte
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 169 && bytes[1] == 254)
    }
}
