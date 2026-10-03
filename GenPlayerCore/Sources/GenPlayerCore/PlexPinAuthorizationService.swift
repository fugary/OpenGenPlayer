import Foundation

#if canImport(UIKit)
import UIKit
#endif

public struct PlexLoginPin: Equatable {
    public let id: Int
    public let code: String
    public let authToken: String?
    public let qrURL: URL?
}

public final class PlexPinAuthorizationService {
    public static let shared = PlexPinAuthorizationService()

    private let clientName = "GenPlayer"
    private let clientVersion = "1.0"
    private let deviceIdKey = "PlexDeviceId"
    private let session: URLSession
    private let deviceId: String

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)

        if let storedId = UserDefaults.standard.string(forKey: deviceIdKey) {
            deviceId = storedId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: deviceIdKey)
            deviceId = newId
        }
    }

    public func createLoginPin() async throws -> PlexLoginPin {
        guard let url = URL(string: "https://plex.tv/api/v2/pins") else {
            throw PlexPinAuthorizationError.invalidResponse
        }

        var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexPinAuthorizationError.invalidResponse
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? Int,
            let code = json["code"] as? String
        else {
            throw PlexPinAuthorizationError.invalidResponse
        }

        return PlexLoginPin(
            id: id,
            code: code,
            authToken: json["authToken"] as? String,
            qrURL: (json["qr"] as? String).flatMap(URL.init(string:))
        )
    }

    public func linkURL(for pin: PlexLoginPin) -> URL? {
        var components = URLComponents(string: "https://plex.tv/link/")
        components?.queryItems = [
            URLQueryItem(name: "pin", value: pin.code)
        ]
        return components?.url
    }

    public func authorizationURL(for pin: PlexLoginPin) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")
        var fragmentComponents = URLComponents()
        fragmentComponents.queryItems = [
            URLQueryItem(name: "clientID", value: deviceId),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: clientName),
            URLQueryItem(name: "context[device][version]", value: clientVersion),
            URLQueryItem(name: "context[device][platform]", value: platformName),
            URLQueryItem(name: "context[device][platformVersion]", value: platformVersion),
            URLQueryItem(name: "context[device][device]", value: deviceModel),
            URLQueryItem(name: "context[device][deviceName]", value: deviceName)
        ]

        if let query = fragmentComponents.percentEncodedQuery, !query.isEmpty {
            components?.fragment = "?\(query)"
        }

        return components?.url
    }

    public func pollLoginPin(id: Int, code: String) async throws -> PlexLoginPin {
        var components = URLComponents(string: "https://plex.tv/api/v2/pins/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "code", value: code)
        ]

        guard let url = components?.url else {
            throw PlexPinAuthorizationError.invalidResponse
        }

        var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexPinAuthorizationError.invalidResponse
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pinId = json["id"] as? Int,
            let code = json["code"] as? String
        else {
            throw PlexPinAuthorizationError.invalidResponse
        }

        return PlexLoginPin(
            id: pinId,
            code: code,
            authToken: json["authToken"] as? String,
            qrURL: (json["qr"] as? String).flatMap(URL.init(string:))
        )
    }

    private func applyPlexHeaders(to request: inout URLRequest) {
        request.setValue(clientName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(deviceModel, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(platformName, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(platformVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(deviceId, forHTTPHeaderField: "X-Plex-Client-Identifier")
    }

    private var platformName: String {
        #if os(tvOS)
        return "tvOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "Unknown"
        #endif
    }

    private var platformVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private var deviceModel: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(iOS)
        return UIDevice.current.model
        #elseif os(macOS)
        return "Mac"
        #else
        return "Device"
        #endif
    }

    private var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "GenPlayer"
        #endif
    }
}

public enum PlexPinAuthorizationError: LocalizedError {
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return NSLocalizedString("Plex server returned an invalid response", comment: "")
        }
    }
}
