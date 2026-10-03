import Foundation
func platformShellString(_ key: String) -> String { key }
enum VODService { static let defaultUserAgent = "GenPlayer-Test" }
struct VODEpisode { let name: String }
final class FixtureProtocol: URLProtocol {
    static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.requests.append(path)
        let status = path == "/missing.ts" ? 404 : 200
        let body: String
        switch path {
        case "/good.m3u8": body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nchild.m3u8\n"
        case "/child.m3u8": body = "#EXTM3U\n#EXTINF:2,\nsegment.ts\n"
        case "/bad.m3u8": body = "#EXTM3U\n#EXTINF:2,\nmissing.ts\n"
        case "/html.m3u8": body = "<!DOCTYPE html><html>error</html>"
        case "/loop.m3u8": body = "#EXTM3U\nloop.m3u8\n"
        case "/empty": body = ""
        default: body = "media sample"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Checks {
    static func main() async throws {
        var count = 0
        func check(_ result: Bool) { precondition(result); count += 1 }
        let probe = MacVODAddressProbe(protocols: [FixtureProtocol.self])
        func url(_ path: String) -> URL { URL(string: "https://fixture.invalid/" + path)! }
        let good = try await probe.check(url("good.m3u8"))
        check(good.reachable)
        check(FixtureProtocol.requests == ["/good.m3u8", "/child.m3u8", "/segment.ts"])
        _ = try await probe.check(url("good.m3u8"))
        check(FixtureProtocol.requests.count == 3)
        _ = try await probe.check(url("good.m3u8"), force: true)
        check(FixtureProtocol.requests.count == 6)
        let bad = try await probe.check(url("bad.m3u8"))
        check(!bad.reachable && bad.text == "HTTP 404")
        let html = try await probe.check(url("html.m3u8"))
        check(!html.reachable)
        let empty = try await probe.check(url("empty"))
        check(!empty.reachable)
        let loop = try await probe.check(url("loop.m3u8"))
        check(!loop.reachable)
        let unsupported = try await probe.check(URL(string: "file:///private/tmp/not-media")!)
        check(!unsupported.reachable)
        check(MacVODEpisodeMatch.key("第01集") == MacVODEpisodeMatch.key("EP1"))
        check(MacVODEpisodeMatch.key("20260920") != MacVODEpisodeMatch.key("20260921"))
        check(MacVODEpisodeMatch.match(.init(name: "第2集"), in: [.init(name: "EP1"), .init(name: "EP2")])?.name == "EP2")
        check(MacVODEpisodeMatch.match(.init(name: "第2集"), in: [.init(name: "EP2"), .init(name: "第02集")]) == nil)
        check(MacVODEpisodeMatch.match(.init(name: "第2集"), in: [.init(name: "EP1")]) == nil)
        print("PASS: \(count) VOD probe and episode matching checks; mocked HTTP, no GUI")
    }
}
