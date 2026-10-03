import Foundation
import GenPlayerCore

public class MacMediaReportingService {
    public static let shared = MacMediaReportingService()
    
    private let session: URLSession
    
    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "MacDeviceId") {
            return id
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "MacDeviceId")
            return newId
        }
    }
    
    private var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Unknown"
        #endif
    }
    
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: config)
    }
    
    private func authHeader(server: ServerConfig) -> String {
        let clientName = "GenPlayer macOS"
        let clientVersion = "1.0"
        let parts = [
            "Client=\"\(clientName)\"",
            "Device=\"\(deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(clientVersion)\"",
            "Token=\"\(server.accessToken ?? "")\""
        ]
        return "MediaBrowser " + parts.joined(separator: ", ")
    }
    
    private func reportJellyfinEmby(
        server: ServerConfig,
        endpoint: String,
        itemId: String,
        positionTicks: Int64,
        isPaused: Bool,
        playSessionId: String?,
        mediaSourceId: String?
    ) async {
        let baseURL = server.fullURL
        let path = endpoint.isEmpty ? "/Sessions/Playing" : "/Sessions/Playing/\(endpoint)"
        guard var components = URLComponents(string: "\(baseURL)\(path)") else { return }
        if server.type == .emby, let token = server.accessToken {
            components.queryItems = [URLQueryItem(name: "api_key", value: token)]
        }
        guard let url = components.url else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if server.type == .jellyfin {
            request.setValue(authHeader(server: server), forHTTPHeaderField: "X-Emby-Authorization")
        } else if server.type == .emby {
            request.setValue(authHeader(server: server), forHTTPHeaderField: "X-Emby-Authorization")
        }
        
        let payload: [String: Any] = [
            "ItemId": itemId,
            "IsPaused": isPaused,
            "PositionTicks": positionTicks,
            "PlaySessionId": playSessionId ?? "",
            "MediaSourceId": mediaSourceId ?? "",
            "PlayMethod": "DirectPlay"
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("[MacMediaReportingService] Playback report failed: HTTP \(http.statusCode)")
            }
        } catch {
            print("[MacMediaReportingService] Error reporting \(endpoint) to \(server.type): \(error)")
        }
    }
    
    private func reportPlex(
        server: ServerConfig,
        itemId: String,
        positionTicks: Int64,
        isPaused: Bool,
        eventName: String
    ) async {
        let baseURL = server.fullURL
        let state: String
        switch eventName {
        case "playing": state = "playing"
        case "progress": state = isPaused ? "paused" : "playing"
        case "stopped": state = "stopped"
        default: state = "playing"
        }
        
        let time = positionTicks / 10000 // Convert ticks to ms
        
        let urlString = "\(baseURL)/:/timeline?ratingKey=\(itemId)&key=%2Flibrary%2Fmetadata%2F\(itemId)&state=\(state)&time=\(time)&duration=0&hasMDE=1"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("GenPlayer macOS", forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.addValue(server.accessToken ?? "", forHTTPHeaderField: "X-Plex-Token")
        
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("[MacMediaReportingService] Playback report failed: HTTP \(http.statusCode)")
            }
        } catch {
            print("[MacMediaReportingService] Error reporting timeline to Plex: \(error)")
        }
    }
    
    public func reportPlayback(payload: MacServerPlaybackSyncPayload, server: ServerConfig) async {
        // Playback emits progress_periodic / progress_pause / progress_seek, etc.
        let event = payload.eventName.hasPrefix("progress_") ? "progress" : payload.eventName
        var server = server
        if !payload.token.isEmpty { server.accessToken = payload.token }
        switch payload.serverType {
        case .jellyfin, .emby:
            let endpoint: String
            switch event {
            case "playing": endpoint = ""
            case "progress": endpoint = "Progress"
            case "stopped": endpoint = "Stopped"
            default: return
            }
            await reportJellyfinEmby(
                server: server,
                endpoint: endpoint,
                itemId: payload.itemId,
                positionTicks: payload.positionTicks,
                isPaused: payload.isPaused,
                playSessionId: nil,
                mediaSourceId: nil
            )
            
        case .plex:
            await reportPlex(
                server: server,
                itemId: payload.itemId,
                positionTicks: payload.positionTicks,
                isPaused: payload.isPaused,
                eventName: event
            )
            
        default:
            break
        }
    }
}
