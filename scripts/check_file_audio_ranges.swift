import Foundation

@main struct FileAudioRangeChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ text: String) { precondition(condition, text); checks += 1; print("PASS: \(text)") }
    static func rejects(_ text: String, _ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure(text) } catch { check(true, text) }
    }
    static func main() async throws {
        let ports = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String:Int]
        let base = "http://127.0.0.1:\(ports["http"]!)"
        func http(_ path: String, secrets: Bool = false) -> HTTPAudioRangeSource {
            HTTPAudioRangeSource {
                var r = URLRequest(url: URL(string: base + path)!)
                if secrets { r.setValue("secret", forHTTPHeaderField:"Authorization"); r.setValue("cookie", forHTTPHeaderField:"Cookie") }
                return r
            }
        }
        let source = http("/ok")
        let version = try await source.metadata()
        check(version.size == 2097152 && version.stamp == "etag:\"one\"", "HTTP size and strong version come from one-byte probe")
        for offset in [0, 511, 1933271] {
            let data = try await source.read(offset: UInt64(offset), count: 73)
            check(data == Data((offset..<(offset+73)).map { UInt8($0 % 256) }), "HTTP exact bytes at \(offset)")
        }
        await rejects("HTTP rejects negative count without trapping") { _ = try await source.read(offset: 0, count: -1) }
        await rejects("HTTP rejects out-of-file range") { _ = try await source.read(offset: 2097150, count: 3) }
        await rejects("HTTP rejects ranges above 1 MiB") { _ = try await source.read(offset: 0, count: 1048577) }
        for path in ["ignore","wrong","compressed","noversion","weak","baddate","short","overflow","loop"] {
            await rejects("HTTP rejects \(path) response") { _ = try await http("/"+path).metadata() }
        }
        let changed = http("/changed"); _ = try await changed.metadata()
        await rejects("HTTP refuses changed bytes before buffering") { _ = try await changed.read(offset: 10, count: 2) }
        let date = http("/date"); _ = try await date.metadata(); _ = try await date.read(offset: 10, count: 2)
        check(true, "Last-Modified fallback supports range validation")
        let redirected = http("/redirect",secrets:true); _ = try await redirected.metadata(); _ = try await redirected.read(offset: 10, count: 2)
        let slow = Task { try await http("/slow").metadata() }
        try await Task.sleep(nanoseconds: 50_000_000); slow.cancel()
        await rejects("HTTP cancellation terminates an outstanding request") { _ = try await slow.value }
        func ftp(_ name: String) -> FTPAudioRangeSource { FTPAudioRangeSource(url: URL(string:"ftp://fixture:password@127.0.0.1:\(ports["ftp"]!)/\(name).mp4")!) }
        let ftpSource = ftp("ok")
        check(try await ftpSource.metadata().size == 2097152, "FTP probes size and modification time")
        for offset in [1573011, 0, 2031616, 256] {
            let data = try await ftpSource.read(offset: UInt64(offset), count: 8192)
            check(data == Data((offset..<(offset+8192)).map { UInt8($0%256) }), "FTP persistent connection reads exact bytes at \(offset)")
        }
        _ = try await ftpSource.metadata()
        let pasv = ftp("pasv"); _ = try await pasv.metadata()
        check(try await pasv.read(offset: 1024, count: 16) == Data(0..<16), "FTP PASV fallback ignores supplied foreign host")
        let rejected = ftp("no-rest"); _ = try await rejected.metadata()
        await rejects("FTP refuses RETR when REST is rejected") { _ = try await rejected.read(offset: 1024, count: 16) }
        let modified = ftp("changed"); _ = try await modified.metadata(); _ = try await modified.read(offset: 1024, count: 16)
        await rejects("FTP detects file modification between segments") { _ = try await modified.metadata() }
        let slowFTP = ftp("slow"); _ = try await slowFTP.metadata()
        let pendingFTP = Task { try await slowFTP.read(offset: 32, count: 16) }
        try await Task.sleep(nanoseconds: 80_000_000); pendingFTP.cancel()
        await rejects("FTP cancellation interrupts pending data read") { _ = try await pendingFTP.value }
        let windowed = ftp("windows"); _ = try await windowed.metadata()
        for offset in stride(from: 0, to: 1024 * 1024, by: 1024) {
            let data = try await windowed.read(offset: UInt64(offset), count: 16)
            precondition(data == Data(0..<16))
        }
        check(true, "FTP serves dense small ranges from bounded windows")
        let crossing = try await windowed.read(offset: 262136, count: 32)
        check(crossing == Data((262136..<262168).map { UInt8($0 % 256) }), "FTP handles ranges crossing window boundaries")
        let budget = ftp("budget"); _ = try await budget.metadata()
        await rejects("FTP stops sparse reads at its transport budget") {
            for i in 0..<129 { _ = try await budget.read(offset: i % 2 == 0 ? 0 : 1048576, count: 8) }
        }
        await rejects("FTP cannot reuse a cached window after exhausting its budget") {
            _ = try await budget.read(offset: 0, count: 8)
        }
        let (statsData, _) = try await URLSession.shared.data(from: URL(string:base+"/stats")!)
        let stats = try JSONSerialization.jsonObject(with: statsData) as! [String:Any]
        let requests = stats["http"] as! [[String:Any]]
        let normal = requests.filter { $0["path"] as? String == "/ok" }
        check(normal.count == 4 && Set(normal.compactMap { $0["clientPort"] as? Int }).count == 1,
              "HTTP reuses the connection across small ranges")
        let target = requests.filter { ($0["path"] as? String) == "/redirected" }
        check(target.count == 2 && target.allSatisfy { $0["auth"] is NSNull && $0["cookie"] is NSNull }, "cross-origin redirects strip authentication and cookies")
        check(target.last?["range"] as? String == "bytes=10-11" && target.last?["ifRange"] as? String == "\"one\"", "redirect preserves requested range and validator")
        let commands = stats["ftp"] as! [String]
        check(!commands.contains("RETR /no-rest.mp4"), "unsupported FTP does not start a full download")
        check(stats["logins"] as? Int == 7, "FTP reuses one login for multiple reads and metadata probes")
        check(commands.filter { $0 == "RETR /windows.mp4" }.count == 6,
              "1024 small FTP reads use four windows, plus two for a backwards boundary read")
        check(requests.allSatisfy { ($0["range"] as? String)?.hasPrefix("bytes=") == true }, "every media HTTP request is bounded")
        print("PASS: \(checks) file audio transport checks")
        checks = 0
        let reader = FileAudioRangeReader(url: URL(string: base + "/ok")!, provider: nil, serverID: nil, path: nil, itemID: nil)
        _ = try await reader.metadata()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for offset in 1...12 {
                group.addTask {
                    let bytes = try await reader.read(offset: UInt64(offset), count: 31)
                    precondition(bytes == Data((offset..<(offset+31)).map(UInt8.init)))
                }
            }
            try await group.waitForAll()
        }
        check(true, "file reader serializes concurrent range consumers")
        await rejects("file reader bounds invalid offset before transport") { _ = try await reader.read(offset: UInt64.max, count: 1) }
        check(try await reader.read(offset: 256, count: 16) == Data(0..<16), "file reader reopens and validates its version after failure")
        for type in [ServerType.webdav, .alist, .pan115, .onedrive, .googledrive] {
            let endpoint = base + ([ServerType.onedrive, .googledrive].contains(type) ? "/expired-"+type.rawValue : "/ok")
            let server = ServerConfig(id: UUID(), type: type, address: endpoint)
            await MainActor.run { AppNetworkService.shared.servers = [server] }
            let previous = FactoryCalls.shared.values().count
            let source = FileAudioRangeReader(url: URL(string: base + "/untrusted-playback")!, provider: type.rawValue,
                serverID: server.id.uuidString, path: "/movie.mp4", itemID: "original")
            check(FactoryCalls.shared.values().count == previous, "\(type.rawValue) resolver does no work during binding")
            if [.onedrive, .googledrive].contains(type) {
                await rejects("\(type.rawValue) rejects expired file address") { _ = try await source.metadata() }
            }
            _ = try await source.metadata()
            _ = try await source.read(offset: 16, count: 17)
            _ = try await source.read(offset: 200, count: 17)
            let calls = Array(FactoryCalls.shared.values().dropFirst(previous))
            check(calls.count == ([ServerType.onedrive, .googledrive].contains(type) ? 2 : 1), "\(type.rawValue) reuses resolved original URL between ranges")
            if [.onedrive, .googledrive].contains(type) {
                check(calls.last == type.rawValue + "-true", "\(type.rawValue) retry explicitly renews authorization or signed URL")
            }
        }
        let missing = FileAudioRangeReader(url: URL(string: base + "/ok")!, provider: "115", serverID: nil, path: nil, itemID: nil)
        await rejects("cloud file without original identity cannot fall back to playback URL") { _ = try await missing.metadata() }
        for provider in ["plex", "iptv", "vod", "smb"] {
            check(!FileAudioRangeReader.supports(provider: provider, url: URL(string: base+"/movie.mp4")!), "\(provider) remains outside generic file routing")
        }
        print("PASS: \(checks) file audio factory and lifecycle checks")
    }
}
