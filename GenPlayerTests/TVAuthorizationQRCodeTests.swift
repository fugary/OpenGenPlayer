import Foundation
import Testing
#if canImport(GenPlayer)
@testable import GenPlayer
#endif

struct TVAuthorizationQRCodeTests {
    @Test func currentTVCloudCodesAndLegacyCameraLinksReachTheSameSession() {
        for provider in ["googledrive", "onedrive"] {
            let expected = TVAuthorizationQRCode.pairing(.init(ip: "192.168.1.8", port: 49152, secret: "ABC234", provider: provider))
            #expect(TVAuthorizationQRCode.parse("http://192.168.1.8:49152/pair?secret=ABC234&type=\(provider)") == expected)
            #expect(TVAuthorizationQRCode.parse("genplayer://pair?ip=192.168.1.8&port=49152&secret=ABC234&type=\(provider)") == expected)
        }
    }

    @Test(arguments: ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.0.1", "169.254.1.1"])
    func acceptsTVLocalAddresses(_ ip: String) {
        #expect(TVAuthorizationQRCode.parse("http://\(ip):8080/pair?secret=ABC234&type=onedrive") != nil)
    }

    @Test(arguments: ["8.8.8.8", "127.0.0.1", "0.0.0.0", "172.15.0.1", "172.32.0.1", "192.169.0.1",
                      "192.168.1.999", "192.168.01.1", "3232235777", "localhost", "tv.example.com"])
    func rejectsNonLocalOrAmbiguousAddresses(_ ip: String) {
        #expect(TVAuthorizationQRCode.parse("genplayer://pair?ip=\(ip)&port=8080&secret=ABC234&type=googledrive") == nil)
    }

    @Test(arguments: [
        "http://192.168.1.8:8080/pair?secret=ABC234", // no implicit Google fallback
        "http://192.168.1.8:8080/pair?secret=ABC234&type=plex",
        "http://192.168.1.8:8080/pair?secret=ABC234&type=onedrive&type=googledrive",
        "http://192.168.1.8:8080/pair?secret=ABC234&secret=XYZ234&type=onedrive",
        "http://192.168.1.8:0/pair?secret=ABC234&type=onedrive",
        "http://192.168.1.8:65536/pair?secret=ABC234&type=onedrive",
        "http://192.168.1.8/pair?secret=ABC234&type=onedrive",
        "http://user@192.168.1.8:8080/pair?secret=ABC234&type=onedrive",
        "http://192.168.1.8:8080/pair?secret=ABC234&type=onedrive#other",
        "http://192.168.1.8:8080/pair?secret=ABC%2F34&type=onedrive",
        "genplayer://pair?ip=192.168.1.8%2Fother&port=8080&secret=ABC234&type=onedrive",
        "genplayer://pair/other?ip=192.168.1.8&port=8080&secret=ABC234&type=onedrive",
        "https://192.168.1.8:8080/pair?secret=ABC234&type=onedrive"
    ])
    func rejectsMalformedPairingRequests(_ code: String) {
        #expect(TVAuthorizationQRCode.parse(code) == nil)
    }

    @Test func plexOnlyOpensCanonicalOfficialBindingPage() {
        let expected = TVAuthorizationQRCode.plex(URL(string: "https://plex.tv/link/?pin=AB12")!)
        #expect(TVAuthorizationQRCode.parse("https://plex.tv/link/?pin=AB12") == expected)
        #expect(TVAuthorizationQRCode.parse("https://plex.tv:443/link?pin=AB12&next=https://example.com") == expected)
    }

    @Test(arguments: ["https://plex.tv.evil.test/link?pin=AB12", "https://evil.test/plex.tv/link?pin=AB12",
                      "https://plex.tv@evil.test/link?pin=AB12", "http://plex.tv/link?pin=AB12",
                      "https://plex.tv:8080/link?pin=AB12", "https://plex.tv/link?pin=AB12&pin=CD34",
                      "https://plex.tv/link?pin=AB%2F2", "https://plex.tv/link", "https://plex.tv/other?pin=AB12"])
    func rejectsSpoofedOrInvalidPlexLinks(_ code: String) {
        #expect(TVAuthorizationQRCode.parse(code) == nil)
    }

    @Test func recognizes115WithoutOpeningItsCode() {
        #expect(TVAuthorizationQRCode.parse("http://115.com/scan/dg-example") == .pan115)
        #expect(TVAuthorizationQRCode.parse("https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode?uid=example") == .pan115)
        #expect(TVAuthorizationQRCode.parse("https://115.com.evil.test/scan") == nil)
    }

    @Test(arguments: ["", "not a URL", "https://example.com", "javascript:alert(1)", "file:///tmp/example", String(repeating: "A", count: 2049)])
    func rejectsUnknownCodes(_ code: String) {
        #expect(TVAuthorizationQRCode.parse(code) == nil)
    }
}
