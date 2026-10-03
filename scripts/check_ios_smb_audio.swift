import Foundation
import AVFoundation
import GenPlayerCore

extension IOSSubtitleIntelligenceChecks {
    @MainActor static func smbChecks(fixture: URL, root: URL) async throws {
        guard #available(macOS 26.0, *) else { throw MacAudioSubtitleError.unavailable }
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1; print("PASS: \(message)")
        }
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            preconditionFailure("SMB adapter timed out")
        }
        let bytes = try Data(contentsOf: fixture), transport = IOSSMBAudioTestTransport.shared
        await transport.configure(bytes: bytes)
        let suite = "IOSSMBAudioChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var transcriptions = 0
        let backend = MacAudioSubtitleBackend(inspect: { _ in throw MacAudioSubtitleError.unreadable },
            languages: { ["en-US", "ja-JP"] }, available: { true }, prepare: { _ in },
            transcribe: { source, track, _, chunk in
                precondition(source.fileAudio != nil && source.remote == nil && track == 2)
                transcriptions += 1
                let output = root.appendingPathComponent(UUID().uuidString + ".caf")
                defer { try? FileManager.default.removeItem(at: output) }
                let start = Double(chunk) * 30
                try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: track, start: start, end: start + 1,
                    format: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, to: output)
                let decoded = try AVAudioFile(forReading: output)
                precondition(decoded.length == 16000)
                // No speech engine runs. Hold one decoded chunk to exercise cancellation.
                try? await Task.sleep(nanoseconds: 150_000_000)
                return [.init(id: chunk * 10000, start: start, end: start + 1, text: "fixture")]
            }, revision: "ios-smb-fixture")
        let audio = MacAudioSubtitleJob(backend: backend, store: MacAudioSubtitleStore(root: root.appendingPathComponent("smb-cache")), defaults: defaults)
        let model = IOSSubtitleIntelligence(audio: audio, translation: MacSubtitleTranslation(defaults: defaults))
        let url = URL(string: "smb://test:secret@fixture.invalid/share/folder/movie.MP4")!
        func bind(_ value: URL = url, provider: String = "smb", server: String = "server-A", live: Bool = false) {
            model.bind(url: value, live: live, provider: provider, serverID: server, itemID: nil,
                       serverURL: nil, token: nil, mediaSourceID: nil)
        }
        func openAudio() { model.presentSettings(audio: true); model.prepareAudioSettings() }
        bind()
        check(!audio.inspecting && audio.source == nil && audio.status == "AS.Ready", "iOS SMB binding remains lazy")
        check(await transport.stats().metadata == 0, "ordinary SMB playback performs no metadata or login work")
        model.presentSettings(audio: false); model.prepareAudioSettings()
        check(await transport.stats().metadata == 0, "primary translation settings do not inspect SMB audio")
        model.setBackground(true); openAudio()
        check(await transport.stats().metadata == 0, "background page callback cannot start SMB inspection")
        model.setBackground(false); openAudio()
        try await until { !audio.inspecting }
        check(audio.source?.fileAudio != nil && audio.source?.remote == nil, "audio settings bind SMB to the file audio path")
        check(audio.source?.tracks.map(\.id) == [1, 2] && audio.source?.tracks.map(\.ordinal) == [1, 2], "iOS keeps MP4 track identifiers and ordinals")
        check(audio.source?.tracks.map(\.language) == ["en", "ja"], "iOS keeps MP4 track languages")
        let inspection = await transport.stats()
        check(inspection.metadata == 2 && inspection.transferred < bytes.count / 10, "iOS inspection reads only the MP4 index")
        let expected = MacAudioSubtitlePlan.digest(["server-A", "smb://fixture.invalid/share/folder/movie.MP4"])
        check(audio.source?.fileAudio?.access.identity == expected, "cache identity excludes SMB credentials and matches macOS")
        let identity = audio.source!.identity
        audio.selectedTrack = 2; audio.language = "ja-JP"
        model.updateAudioNames([(101, "English"), (202, "Japanese")])
        audio.useOrGenerate()
        try await until { !audio.running && audio.cache?.isComplete == true }
        check(model.generatedName == "(Generated)Japanese", "iOS generated subtitle name follows the original audio ordinal")
        check(transcriptions == 3 && audio.cues.count == 3 && model.isGeneratedPrimary, "SMB segments decode through the iOS model and populate primary subtitles")
        let completedCount = transcriptions
        bind(URL(string: "smb://changed:password@fixture.invalid/share/folder/movie.MP4")!)
        check(audio.source == nil && !audio.running, "SMB cache reopening waits for explicit audio page entry")
        openAudio()
        try await until { !audio.inspecting && !audio.running && audio.cache?.isComplete == true }
        check(audio.source?.identity == identity && transcriptions == completedCount, "credential changes preserve the completed cache without recognition")
        bind(URL(string: "smb://fixture.invalid/share/folder/next.m4v")!); openAudio()
        try await until { audio.running }
        check(audio.activeTrack == 2 && audio.activeLanguage == "ja-JP", "same SMB directory inherits track and dialogue language")
        model.setBackground(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        check(!audio.running, "iOS background cancels SMB generation")
        let afterBackground = transcriptions
        model.setBackground(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        check(!audio.running && transcriptions == afterBackground, "foreground does not restart SMB generation")
        bind(url, server: "server-B"); openAudio()
        try await until { !audio.inspecting }
        check(audio.source?.identity != identity && !audio.running && audio.selectedTrack == -1, "another SMB server does not inherit cached audio selection")
        bind(URL(string: "smb://fixture.invalid/share/another/movie.mp4")!); openAudio()
        try await until { !audio.inspecting }
        check(!audio.running && audio.selectedTrack == -1, "another SMB directory does not inherit track selection")
        model.reset()
        await transport.configure(bytes: bytes, fails: true)
        bind(); openAudio()
        try await until { !audio.inspecting }
        check(audio.source == nil && audio.status == "AS.SMBFailed", "SMB connection failure has its own recovery message")
        await transport.configure(bytes: bytes, delay: 30_000_000)
        openAudio(); openAudio()
        try await until { !audio.inspecting && !audio.running }
        let recovered = await transport.stats()
        check(audio.source != nil && recovered.metadata == 2, "reopening recovers SMB tracks and coalesces duplicate page entries")
        model.reset()
        await transport.configure(bytes: bytes, delay: 150_000_000)
        bind(); openAudio()
        try await Task.sleep(nanoseconds: 30_000_000)
        bind(URL(string: "https://fixture.invalid/other.mp4")!, provider: "webdav")
        try await Task.sleep(nanoseconds: 250_000_000)
        check(audio.source == nil && !audio.inspecting && audio.status == "AS.Ready", "late SMB inspection cannot restore a replaced video")
        check(await transport.stats().reads == 0, "cancelled SMB metadata cannot start index reads")
        await transport.configure(bytes: Data(count: 64))
        bind(); openAudio()
        try await until { !audio.inspecting }
        check(audio.source == nil && audio.status == "AS.SMBUnsupported", "unsupported SMB container reports format failure without downloading")
        await transport.configure(bytes: bytes)
        for provider in ["webdav", "ftp", "sftp", "nfs", "alist", "onedrive", ""] {
            bind(url, provider: provider); openAudio()
            check(audio.source == nil && !audio.inspecting && audio.status == "AS.LocalOnly", "\(provider) is not routed through SMB audio")
        }
        for name in ["movie.mkv", "audio.m4a"] {
            bind(URL(string: "smb://fixture.invalid/share/" + name)!); openAudio()
            check(!audio.inspecting && audio.status == "AS.LocalOnly", "iOS \(name) does not enable the SMB video adapter")
        }
        bind(URL(string: "https://fixture.invalid/movie.mp4")!); openAudio()
        check(audio.status == "AS.LocalOnly", "SMB provider with a non-SMB URL is rejected")
        bind(live: true); openAudio()
        check(audio.status == "AS.LocalOnly", "live SMB media does not enable audio generation")
        check(await transport.stats().metadata == 0, "excluded providers and media never touch the SMB transport")
        model.reset()
        print("PASS: \(checks) iOS SMB audio adapter checks")
        checks = 0
        var identities = Set<String>()
        for provider in ["webdav", "ftp", "sftp", "nfs", "alist", "115", "onedrive", "googledrive"] {
            let scheme = ["ftp", "sftp", "nfs"].contains(provider) ? provider : "https"
            let endpoint = URL(string: "\(scheme)://fixture.invalid/raw?token=first")!
            await transport.configure(bytes: bytes)
            model.bind(url: endpoint, live: false, provider: provider, serverID: "server-A", itemID: "file-id",
                serverURL: nil, token: nil, mediaSourceID: nil, filePath: "/Movies/movie.mp4")
            let stats = await transport.stats()
            check(audio.source == nil && !audio.inspecting && stats.metadata == 0,
                  "\(provider) binding stays lazy and recognizes the original file extension")
            openAudio(); try await until { !audio.inspecting }
            check(audio.source?.fileAudio?.access.kind == provider && audio.source?.tracks.map(\.id) == [1, 2],
                  "\(provider) inspects the selected file with original track IDs")
            let identity = audio.source!.identity
            identities.insert(identity)
            model.bind(url: URL(string: "\(scheme)://other-cdn.invalid/renewed?token=second")!, live: false,
                provider: provider, serverID: "server-A", itemID: "file-id", serverURL: nil, token: nil,
                mediaSourceID: nil, filePath: "/Movies/movie.mp4")
            openAudio(); try await until { !audio.inspecting }
            check(audio.source?.identity == identity, "\(provider) address renewal preserves stable file identity")
            if provider == "webdav" {
                let before = transcriptions
                audio.selectedTrack = 2; audio.language = "ja-JP"; audio.useOrGenerate()
                try await until { !audio.running && audio.cache?.isComplete == true }
                check(transcriptions == before + 3 && model.isGeneratedPrimary,
                      "WebDAV generates selected-track segments through the iOS model")
            }
            model.reset()
        }
        check(identities.count == 8, "file service cache namespaces remain isolated")
        await transport.configure(bytes: bytes, fails: true)
        bind(URL(string: "https://fixture.invalid/movie.mp4")!, provider: "webdav"); openAudio()
        try await until { !audio.inspecting }
        check(audio.source == nil && audio.status == "AS.FileFailed", "remote file failures use protocol-neutral recovery text")
        await transport.configure(bytes: Data(count: 64))
        openAudio(); try await until { !audio.inspecting }
        check(audio.source == nil && audio.status == "AS.FileUnsupported", "invalid remote MP4 fails without full download fallback")
        model.reset()
        print("PASS: \(checks) iOS file service audio adapter checks")
        checks = 0
        await transport.configure(bytes: bytes)
        model.onPlaybackAudioSelection = { (1, [-1, 0, 1]) }
        bind(url, server: "default-track-server"); openAudio()
        try await until { !audio.inspecting }
        check(audio.selectedTrack == 2 && !audio.running, "iOS file audio defaults to current playback ordinal despite colliding IDs")
        audio.selectedTrack = 1
        model.prepareAudioSettings(); model.refreshDefaultAudioTrack()
        check(audio.selectedTrack == 1, "reopening iOS settings keeps a manually selected recognition track")
        let inspected = audio.source!
        var supportedSubset = inspected
        supportedSubset = .init(url: inspected.url, identity: inspected.identity, duration: inspected.duration,
            tracks: [inspected.tracks[1]], fileAudio: inspected.fileAudio)
        check(supportedSubset.playingTrack(id: 0, trackIDs: [-1, 0, 1]) == nil,
              "unsupported playing track does not default to the sole readable AAC track")
        check(supportedSubset.playingTrack(id: 1, trackIDs: [-1, 0, 1])?.id == 2,
              "filtered file tracks retain their original playback ordinal")
        model.reset()
        model.onPlaybackAudioSelection = nil
        print("PASS: \(checks) iOS default audio selection checks")
        checks = 0
        // Different query-selected resources may legally share validators and MP4 tables.
        var other = bytes
        let index = try await MP4AudioIndex.inspect(size: UInt64(bytes.count)) { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        let samples = index.tracks[1].samples
        var swapped = false
        for a in samples.indices where !swapped {
            for b in samples.indices where b > a && samples[b].size == samples[a].size {
                let ra = Int(samples[a].offset)..<(Int(samples[a].offset) + Int(samples[a].size))
                let rb = Int(samples[b].offset)..<(Int(samples[b].offset) + Int(samples[b].size))
                if bytes.subdata(in: ra) != bytes.subdata(in: rb) {
                    other.replaceSubrange(ra, with: bytes.subdata(in: rb))
                    other.replaceSubrange(rb, with: bytes.subdata(in: ra))
                    swapped = true; break
                }
            }
        }
        precondition(swapped && other != bytes)
        func bindQuery(_ id: String) {
            model.bind(url: URL(string: "https://fixture.invalid/query/movie.mp4?file=" + id)!, live: false,
                provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
            openAudio()
        }
        await transport.configure(bytes: bytes)
        bindQuery("A"); try await until { !audio.inspecting }
        let firstIdentity = audio.source!.identity
        audio.selectedTrack = 2; audio.language = "ja-JP"; audio.useOrGenerate()
        try await until { !audio.running && audio.cache?.isComplete == true }
        let firstCount = transcriptions
        await transport.configure(bytes: other)
        bindQuery("B"); try await until { !audio.inspecting && !audio.running }
        check(audio.source?.identity != firstIdentity && audio.cache?.isComplete == true && transcriptions == firstCount + 3,
              "query-selected HTTP files with equal version and MP4 tables generate independent subtitles")

        model.reset()
        let queryA = URL(string: "https://user:secret@fixture.invalid/movie.mp4?file=A&signature=first#fragment")!
        let queryB = URL(string: "https://fixture.invalid/movie.mp4?file=B&signature=first")!
        let a = MP4AudioAccess.fileIdentity(url: queryA, provider: nil, serverID: nil, path: nil)!
        let b = MP4AudioAccess.fileIdentity(url: queryB, provider: nil, serverID: nil, path: nil)!
        check(a.identity != b.identity && a.scope == b.scope, "HTTP query identifies media but not its parent directory")
        let withoutCredentials = URL(string: "https://fixture.invalid/movie.mp4?file=A&signature=first")!
        check(a.identity == MP4AudioAccess.fileIdentity(url: withoutCredentials, provider: nil, serverID: nil, path: nil)?.identity,
              "HTTP identity strips credentials and fragments without discarding resource parameters")
        let incompleteA = MP4AudioAccess.fileIdentity(url: queryA, provider: "webdav", serverID: "server", path: nil)!
        let incompleteB = MP4AudioAccess.fileIdentity(url: queryB, provider: "webdav", serverID: "server", path: nil)!
        check(incompleteA.identity != incompleteB.identity, "server ID without original file path cannot collapse query resources")
        print("PASS: \(checks) HTTP cache isolation checks")

    }
}
