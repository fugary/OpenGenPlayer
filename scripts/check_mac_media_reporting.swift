import Foundation
import GenPlayerCore

final class ReportingProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.requests.append(captured)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ReportingChecks {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReportingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let reporter = MacMediaReportingService(session: session)
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1; print("PASS: \(name)")
        }
        for type: ServerConfig.ServerType in [.jellyfin, .emby] {
            let server = ServerConfig(name: "fixture", address: "example.invalid/base", type: type, accessToken: "stale")
            for (event, path) in [("playing", "/base/Sessions/Playing"), ("progress_periodic", "/base/Sessions/Playing/Progress"),
                                  ("progress_paused", "/base/Sessions/Playing/Progress"), ("progress", "/base/Sessions/Playing/Progress"),
                                  ("stopped", "/base/Sessions/Playing/Stopped")] {
                let previous = ReportingProtocol.requests.count
                await reporter.reportPlayback(payload: .init(serverType: type, serverId: server.id.uuidString,
                    itemId: "movie", userId: "user", token: "current", positionTicks: 420000000,
                    isPaused: event == "progress_paused", eventName: event), server: server)
                check(ReportingProtocol.requests.count == previous + 1, "\(type) sends \(event)")
                let request = ReportingProtocol.requests.last!
                check(request.url?.path == path && request.httpMethod == "POST", "\(event) endpoint and method")
                check(request.value(forHTTPHeaderField: "X-Emby-Authorization")?.contains("Token=\"current\"") == true,
                      "request uses the playback credential")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                check(body["ItemId"] as? String == "movie" && body["PositionTicks"] as? Int64 == 420000000 &&
                      body["IsPaused"] as? Bool == (event == "progress_paused"), "request preserves item, position and pause state")
            }
        }
        let plex = ServerConfig(name: "fixture", address: "example.invalid", type: .plex)
        await reporter.reportPlayback(payload: .init(serverType: .plex, serverId: plex.id.uuidString,
            itemId: "movie", userId: "user", token: "current", positionTicks: 420000000,
            isPaused: true, eventName: "progress_paused"), server: plex)
        let query = URLComponents(url: ReportingProtocol.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(query.first { $0.name == "state" }?.value == "paused", "Plex progress preserves pause state")
        print("PASS: \(checks) reporting checks; all requests intercepted locally")
    }
}
