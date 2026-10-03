import Foundation
import ImageIO
import AppKit

@main enum Checks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, line: Int = #line) { precondition(value, "Check \(count + 1) failed at line \(line)"); count += 1 }
        // Every combination: the foremost visible layer owns Back, including
        // native menus over a drawer and drawers over visible playback controls.
        let layers: [TVPlaybackBackPolicy.Action] = [.nativeMenu, .positionAdjustment, .scrubbing, .playlist, .submenu, .panel, .chrome]
        for mask in 0..<128 {
            let visible = (0..<7).map { mask & (1 << $0) != 0 }
            let result = TVPlaybackBackPolicy.action(nativeMenu: visible[0], positionAdjustment: visible[1],
                scrubbing: visible[2], playlist: visible[3], submenu: visible[4], panel: visible[5], chrome: visible[6])
            check(result == (visible.firstIndex(of: true).map { layers[$0] } ?? .exit))
        }
        for viewport: CGFloat in [720, 1080, 2160] {
            for audio in [false, true] {
                let layout = TVPlaybackDrawerLayout(viewportHeight: viewport, isAudio: audio)
                let short = layout.contentHeight(measured: 170)
                let long = layout.contentHeight(measured: 1800)
                check(short < long)
                check(long == layout.contentLimit)
                check(layout.topInset + 210 + long + 64 <= viewport)
                check(layout.contentHeight(measured: 0) > 0)
            }
        }
        let backNow = Date(timeIntervalSince1970: 100)
        for deadline in [nil, backNow.addingTimeInterval(-1), backNow, backNow.addingTimeInterval(1)] as [Date?] {
            check(TVPlaybackBackPolicy.suppressBackgroundNavigation(playbackActive: true, until: deadline, now: backNow))
            check(TVPlaybackBackPolicy.suppressBackgroundNavigation(playbackActive: false, until: deadline, now: backNow) == (deadline.map { $0 > backNow } ?? false))
        }
        check(MPVPlaybackCachePolicy.allowsExtendedReadAhead(connected: true, expensive: false, constrained: false, wifiOrEthernet: true))
        check(!MPVPlaybackCachePolicy.allowsExtendedReadAhead(connected: false, expensive: false, constrained: false, wifiOrEthernet: true))
        check(!MPVPlaybackCachePolicy.allowsExtendedReadAhead(connected: true, expensive: true, constrained: false, wifiOrEthernet: true))
        check(!MPVPlaybackCachePolicy.allowsExtendedReadAhead(connected: true, expensive: false, constrained: true, wifiOrEthernet: true))
        check(!MPVPlaybackCachePolicy.allowsExtendedReadAhead(connected: true, expensive: false, constrained: false, wifiOrEthernet: false))
        check(MPVPlaybackCachePolicy.readAheadSeconds(extended: true, foreground: true, paused: true) == "86400")
        check(MPVPlaybackCachePolicy.readAheadSeconds(extended: true, foreground: true, paused: false) == "86400")
        check(MPVPlaybackCachePolicy.readAheadSeconds(extended: false, foreground: true, paused: true) == "120")
        check(MPVPlaybackCachePolicy.readAheadSeconds(extended: true, foreground: false, paused: true) == "0")
        check(MPVPlaybackCachePolicy.readAheadSeconds(extended: true, foreground: false, paused: false) == "120")
        let tokenTrack = MacMPVTrack(id: 1, type: "sub", title: "Stream.srt?api_key=OLD_SECRET", language: "en", codec: "subrip", external: true, externalFilename: "https://example.com/Stream.srt?api_key=OLD_SECRET")
        let rotatedTrack = MacMPVTrack(id: 9, type: "sub", title: "Stream.srt?api_key=NEW_SECRET", language: "en", codec: "subrip", external: true, externalFilename: "https://example.com/Stream.srt?api_key=NEW_SECRET")
        let safeChoice = MacMPVTrackChoice.selected(1, in: [tokenTrack])!
        let encodedChoice = try JSONEncoder().encode(safeChoice)
        check(!String(decoding: encodedChoice, as: UTF8.self).contains("SECRET"))
        check(safeChoice.resolve(in: [rotatedTrack]) == 9)
        let unsafeObject: [String: Any] = ["sub": ["signature": ["title": "https%3A%2F%2Fuser%3Apassword%40example.com%2FStream.srt%3Fapi_key%3DOLD_SECRET", "language": "en", "codec": "subrip", "external": true, "source": MacMPVTrackChoice.mediaKey(url: tokenTrack.externalURL!)], "occurrence": 0, "matchCount": 1]]
        let unsafeData = try JSONSerialization.data(withJSONObject: unsafeObject)
        let decodedChoices = try JSONDecoder().decode([String: MacMPVTrackChoice].self, from: unsafeData)
        check(decodedChoices["sub"]?.resolve(in: [rotatedTrack]) == 9)
        let suite = "GenPlayerReviewChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferenceKeys = ["macMPVTrackChoice.test", "ios.macMPVTrackChoice.test", "tv.macMPVTrackChoice.test", "ios.mpv.trackScope.test"]
        for key in preferenceKeys { defaults.set(unsafeData, forKey: key) }
        defaults.set("keep", forKey: "unrelated")
        defaults.set(Data("broken SECRET".utf8), forKey: "macMPVTrackChoice.broken")
        MacMPVTrackChoice.sanitizeStoredPreferences(in: defaults)
        for key in preferenceKeys {
            let data = defaults.data(forKey: key)!
            check(!String(decoding: data, as: UTF8.self).contains("SECRET"))
            check(!String(decoding: data, as: UTF8.self).contains("password"))
            check(try JSONDecoder().decode([String: MacMPVTrackChoice].self, from: data)["sub"]?.resolve(in: [rotatedTrack]) == 9)
        }
        check(defaults.string(forKey: "unrelated") == "keep")
        check(defaults.object(forKey: "macMPVTrackChoice.broken") == nil)
        check(MPVPlaybackCachePolicy.readAheadSeconds(extended: false, foreground: false, paused: true) == "0")
        var diskMonitor = MacMPVDiskCacheMonitor()
        let diskFree: Int64 = 10 * MacMPVDiskCachePolicy.gib
        check(diskMonitor.fallbackReason(bytes: nil, free: diskFree, loaded: false) == nil)
        check(diskMonitor.fallbackReason(bytes: nil, free: diskFree, loaded: true) == nil)
        check(diskMonitor.fallbackReason(bytes: 0, free: diskFree, loaded: true) == nil)
        check(diskMonitor.fallbackReason(bytes: nil, free: diskFree, loaded: true) == nil)
        check(diskMonitor.fallbackReason(bytes: nil, free: diskFree, loaded: true) == nil)
        check(diskMonitor.fallbackReason(bytes: nil, free: diskFree, loaded: true) == .statistics)
        check(diskMonitor.fallbackReason(bytes: 1, free: diskFree, loaded: true) == nil)
        check(diskMonitor.fallbackReason(bytes: 1, free: 0, loaded: false) == .space)
        check(diskMonitor.fallbackReason(bytes: 1, free: nil, loaded: false) == .statistics)
        check(diskMonitor.fallbackReason(bytes: 4 * MacMPVDiskCachePolicy.gib, free: diskFree, loaded: false) == .limit)
        check(!MacMPVDiskCachePolicy.canStart(freeBytes: nil))
        check(!MacMPVDiskCachePolicy.canStart(freeBytes: 6 * MacMPVDiskCachePolicy.gib - 1))
        check(MacMPVDiskCachePolicy.canStart(freeBytes: 6 * MacMPVDiskCachePolicy.gib))
        check(!MacMPVDiskCachePolicy.mustFallBack(fileBytes: 0, freeBytes: 6 * MacMPVDiskCachePolicy.gib))
        check(!MacMPVDiskCachePolicy.mustFallBack(fileBytes: 4 * MacMPVDiskCachePolicy.gib - 1, freeBytes: 2 * MacMPVDiskCachePolicy.gib + 1))
        check(MacMPVDiskCachePolicy.mustFallBack(fileBytes: 4 * MacMPVDiskCachePolicy.gib, freeBytes: 10 * MacMPVDiskCachePolicy.gib))
        check(MacMPVDiskCachePolicy.mustFallBack(fileBytes: 1, freeBytes: 2 * MacMPVDiskCachePolicy.gib))
        check(MacMPVDiskCachePolicy.mustFallBack(fileBytes: nil, freeBytes: 10 * MacMPVDiskCachePolicy.gib))
        check(MacMPVDiskCachePolicy.mustFallBack(fileBytes: 1, freeBytes: nil))
        check(MacMPVDiskCachePolicy.mustFallBack(fileBytes: -1, freeBytes: 10 * MacMPVDiskCachePolicy.gib))
        // Cache display must preserve holes, tolerate eviction, and reject invalid timestamps.
        let cacheRanges = MPVBufferedRange.normalized([
            .init(start: 40, end: 60), .init(start: -5, end: 10),
            .init(start: 8, end: 20), .init(start: 70, end: 120),
            .init(start: .nan, end: 30), .init(start: 20, end: .infinity),
            .init(start: 50, end: 45), .init(start: 15, end: 16)], duration: 100)
        check(cacheRanges == [.init(start: 0, end: 20), .init(start: 40, end: 60), .init(start: 70, end: 100)])
        check(MPVBufferedRange.aheadSeconds(cacheRanges, time: 12, duration: 100) == 8)
        check(MPVBufferedRange.aheadSeconds(cacheRanges, time: 30, duration: 100) == 0) // Future islands do not count.
        check(MPVBufferedRange.aheadSeconds(cacheRanges, time: 50, duration: 100) == 10)
        check(MPVBufferedRange.aheadSeconds(cacheRanges, time: 100, duration: 100) == 0)
        check(MPVBufferedRange.aheadSeconds([], time: 0, duration: 100) == nil)
        check(MPVBufferedRange.aheadSeconds(cacheRanges, time: .nan, duration: 100) == nil)
        check(MPVBufferedRange.aheadSeconds(cacheRanges, time: 0, duration: 0) == nil)
        check(MPVBufferedRange.aheadSeconds([.init(start: 0, end: 10), .init(start: 8, end: 20)], time: 5, duration: 100) == 15)
        check(MPVBufferedRange.normalized(cacheRanges, duration: 0).isEmpty)
        check(MPVBufferedRange.normalized(cacheRanges, duration: .nan).isEmpty)
        check(MPVBufferedRange.normalized([], duration: 100).isEmpty)
        check(MPVBufferedRange.normalized([.init(start: 40, end: 50)], duration: 100) == [.init(start: 40, end: 50)])
        check(MPVBufferedRange.normalized([.init(start: 101, end: 120), .init(start: -10, end: -1)], duration: 100).isEmpty)
        check(MPVPlaybackCachePolicy.options(enabled: false, url: URL(string: "https://example.com/movie")!).isEmpty)
        check(MPVPlaybackCachePolicy.options(enabled: true, url: URL(fileURLWithPath: "/movie.mkv")).isEmpty)
        for scheme in ["rtsp", "rtsps", "rtp", "udp"] {
            check(MPVPlaybackCachePolicy.options(enabled: true, url: URL(string: "\(scheme)://example.com/live")!).isEmpty)
        }
        for scheme in ["https", "smb", "sftp", "nfs"] {
            let options = MPVPlaybackCachePolicy.options(enabled: true, url: URL(string: "\(scheme)://example.com/movie")!)
            check(options["cache"] == "yes" && options["demuxer-seekable-cache"] == "yes")
            check(Int(options["demuxer-max-bytes"]!)! + Int(options["demuxer-max-back-bytes"]!)! <= 96 * 1024 * 1024)
        }
        let mixedSubtitles = ["English SDH · eng", "简体中文 · zho", "繁體中文 · chi"]
        check(PlaybackSubtitleAutoSelection.index(in: mixedSubtitles, mode: "chinese", language: "en") == 1)
        check(PlaybackSubtitleAutoSelection.index(in: mixedSubtitles, mode: "english", language: "zh") == 0)
        check(PlaybackSubtitleAutoSelection.index(in: mixedSubtitles, mode: "followAppLanguage", language: "zh-Hant") == 1)
        check(PlaybackSubtitleAutoSelection.index(in: mixedSubtitles, mode: "followAppLanguage", language: "en_US") == 0)
        check(PlaybackSubtitleAutoSelection.index(in: mixedSubtitles, mode: "off", language: "zh") == nil)
        check(PlaybackSubtitleAutoSelection.index(in: ["Unknown"], mode: "off", language: "zh") == nil)
        check(PlaybackSubtitleAutoSelection.index(in: ["Unknown"], mode: "chinese", language: "zh") == 0)
        check(PlaybackSubtitleAutoSelection.index(in: ["Unknown", "Other"], mode: "chinese", language: "zh") == nil)
        check(PlaybackSubtitleAutoSelection.index(in: ["French", "Signs"], mode: "english", language: "en") == nil)
        check(PlaybackSubtitleAutoSelection.index(in: [], mode: "english", language: "en") == nil)
        check(PlaybackSubtitleAutoSelection.index(in: ["Unknown"], mode: "future-mode", language: "en") == nil)
        for (language, name) in [("ja-JP", "jpn"), ("ko", "한국어"), ("fr", "fre"), ("de", "Deutsch"), ("es", "español")] {
            check(PlaybackSubtitleAutoSelection.index(in: ["Other", name], mode: "followAppLanguage", language: language) == 1)
        }
        let bitmapTrack = MacMPVTrack(id: 3, type: "sub", title: "Signs", language: "en", codec: "hdmv_pgs_subtitle", external: false)
        let textTrack = MacMPVTrack(id: 4, type: "sub", title: "Dialogue", language: "en", codec: "subrip", external: false)
        check(IOSMPVTrackPreference.resolve(query: "Dialogue", ordinal: 0, tracks: [bitmapTrack, textTrack]) == 4)
        check(IOSMPVTrackPreference.resolve(query: "DIALOGUE", ordinal: nil, tracks: [bitmapTrack, textTrack]) == 4)
        check(IOSMPVTrackPreference.resolve(query: "Dialogue", ordinal: nil, tracks: [bitmapTrack]) == nil)
        check(IOSMPVTrackPreference.resolve(query: "missing", ordinal: 1, tracks: [bitmapTrack, textTrack]) == 4)
        check(IOSMPVTrackPreference.resolve(query: " ", ordinal: nil, tracks: [bitmapTrack]) == nil)
        check(IOSMPVTrackPreference.resolve(query: nil, ordinal: -1, tracks: [bitmapTrack]) == nil)
        check(IOSMPVTrackPreference.resolve(query: nil, ordinal: 1, tracks: [bitmapTrack]) == nil)
        check(IOSMPVTrackPreference.resolve(query: "Signs", ordinal: 0, tracks: [bitmapTrack, bitmapTrack]) == nil)
        check(IOSMPVTrackPreference.resolve(query: "Server Subtitle", ordinal: 0, tracks: [bitmapTrack, textTrack], displayNames: ["Signs", "Server Subtitle"]) == 4)
        check(IOSMPVTrackPreference.resolve(query: "Server Subtitle", ordinal: 0, tracks: [bitmapTrack, textTrack], displayNames: ["Server Subtitle"]) == nil)
        check(IOSMPVTrackPreference.resolve(query: "Server Subtitle", ordinal: nil, tracks: [bitmapTrack, textTrack], displayNames: ["Signs", "Loading"]) == nil)
        let bitmapRendering = MPVSecondarySubtitleRendering(trackID: 3, tracks: [bitmapTrack, textTrack])!
        let textRendering = MPVSecondarySubtitleRendering(trackID: 4, tracks: [bitmapTrack, textTrack])!
        check(bitmapRendering.isBitmap && !textRendering.isBitmap)
        check(!bitmapRendering.canSelect(primary: 3) && bitmapRendering.canSelect(primary: 4))
        check(!bitmapRendering.isSelected(primary: 3, secondary: -1)) // No fake text mirror for bitmaps.
        check(bitmapRendering.isSelected(primary: 4, secondary: 3))
        check(textRendering.canSelect(primary: 4) && textRendering.isSelected(primary: 4, secondary: -1))
        check(!textRendering.isSelected(primary: 3, secondary: -1))
        check(MPVSecondarySubtitleRendering(trackID: 3, tracks: [bitmapTrack, bitmapTrack]) == nil)
        check(MPVSecondarySubtitleRendering(trackID: 9, tracks: [bitmapTrack]) == nil)
        check(MPVSecondarySubtitleRendering.nativeDelay(primary: 1.25, secondary: -0.5) == -0.75)
        check(MPVSecondarySubtitleRendering.nativeDelay(primary: .nan, secondary: .infinity) == 0)
        check(MPVSecondarySubtitleRendering.nativePosition(ratio: 0.2) == 20)
        check(MPVSecondarySubtitleRendering.nativePosition(ratio: -0.2) == 0)
        check(MPVSecondarySubtitleRendering.nativePosition(ratio: 2) == 100)
        check(MPVSecondarySubtitleRendering.nativePosition(ratio: .nan) == 100)
        let assTrack = MacMPVTrack(id: 5, type: "sub", title: "Styled", language: "ja", codec: "ass", external: false)
        let ssaTrack = MacMPVTrack(id: 6, type: "sub", title: "External", language: "en", codec: "SSA", external: true)
        let assRendering = MPVSecondarySubtitleRendering(trackID: 5, tracks: [textTrack, assTrack, ssaTrack])!
        let ssaRendering = MPVSecondarySubtitleRendering(trackID: 6, tracks: [ssaTrack])!
        check(assRendering.isASS && !assRendering.isBitmap)
        check(ssaRendering.isASS)
        check(assRendering.rendersASSNatively(primary: 4))
        check(assRendering.rendersASSNatively(primary: -1))
        check(assRendering.rendersASSNatively(primary: 5)) // Same track retains native ASS.
        check(!textRendering.rendersASSNatively(primary: 3))
        check(!bitmapRendering.rendersASSNatively(primary: 4))
        let serverSubtitle = URL(string: "https://server/Videos/item/source/Subtitles/3/Stream.ass?api_key=old")!
        let rotatedSubtitle = URL(string: "https://server/Videos/item/source/Subtitles/3/Stream.ass?api_key=new")!
        let otherVersion = URL(string: "https://server/Videos/item/other/Subtitles/3/Stream.ass")!
        let downloadedTrack = MacMPVTrack(id: 21, type: "sub", title: "Stream.ass", language: "chi", codec: "ass", external: true, externalFilename: serverSubtitle.absoluteString)
        let downloadedChoice = MacMPVTrackChoice.selected(21, in: [downloadedTrack])!
        check(downloadedChoice.resolveExternalAlias([rotatedSubtitle: 5]) == 5)
        check(downloadedChoice.resolveExternalAlias([otherVersion: 5]) == nil)
        check(downloadedChoice.resolveExternalAlias([serverSubtitle: 5, rotatedSubtitle: 6]) == nil)
        check(downloadedChoice.resolveExternalAlias([:]) == nil)
        check(MacMPVTrackChoice.selected(5, in: [assTrack])!.resolveExternalAlias([serverSubtitle: 5]) == nil)
        check(MacMPVTrackChoice.selected(-1, in: [])!.resolveExternalAlias([serverSubtitle: 5]) == nil)
        check(MPVSecondarySubtitleRendering.assOverride(hasCustomPosition: false) == "no")
        check(MPVSecondarySubtitleRendering.assOverride(hasCustomPosition: true) == "no")
        let requestTrack = MacMPVTrack(id: 12, type: "sub", title: "Stream.ass?ApiKey=fixture-secret&api_key=other", language: "chi", codec: "ass", external: true)
        check(requestTrack.subtitleDisplayName(fallback: "字幕 12") == "字幕 12 · chi · ass")
        check(requestTrack.subtitleDisplayName(preferredTitle: "中英字幕", fallback: "字幕 12") == "中英字幕 · chi · ass")
        let urlTrack = MacMPVTrack(id: 13, type: "sub", title: "https://user:password@server/Chinese.ass?token=fixture#private", language: "", codec: "ass", external: true)
        check(urlTrack.subtitleDisplayName(fallback: "字幕 13") == "Chinese.ass")
        check(assTrack.subtitleDisplayName(fallback: "字幕 5") == "Styled · ja · ass")
        check(requestTrack.subtitleDisplayName(preferredTitle: "中文/English", fallback: "字幕 12") == "中文/English · chi · ass")
        let hostOnlyTrack = MacMPVTrack(id: 14, type: "sub", title: "https://user:password@server?token=fixture", language: "", codec: "ass", external: true)
        check(hostOnlyTrack.subtitleDisplayName(fallback: "字幕 14") == "字幕 14 · ass")
        check(MPVSecondarySubtitleRendering.adjustmentRect(bounds: nil, viewport: CGRect(x: 0, y: 0, width: 400, height: 200), fallbackCenterY: 90).midY == 90)
        let viewport = CGRect(x: 50, y: 80, width: 800, height: 450)
        let glyphs = CGRect(x: 0.35, y: 0.7, width: 0.3, height: 0.12)
        let adjustment = MPVSecondarySubtitleRendering.adjustmentRect(bounds: glyphs, viewport: viewport)
        check(adjustment == CGRect(x: 322, y: 389, width: 256, height: 66))
        let windowAdjustment = MPVSecondarySubtitleRendering.adjustmentRect(bounds: glyphs, viewport: CGRect(x: 0, y: 0, width: 900, height: 600))
        check(windowAdjustment.midY == 456 && windowAdjustment.midX == 450)
        check(MPVSecondarySubtitleRendering.adjustmentRect(bounds: nil, viewport: viewport).width == 220)
        let macCapabilities = PlaybackEngineCapabilities(platform: .macOS, engine: .mpv)
        let pausedSession = PlaybackSessionSnapshot(position: 0.35, duration: 90, paused: true, rate: 1.5)
        check(pausedSession.position == 0.35 && pausedSession.paused && pausedSession.rate == 1.5)
        check(pausedSession.replaying() == PlaybackSessionSnapshot(position: 0, duration: 90, paused: false, rate: 1.5))
        check(PlaybackSessionSnapshot(position: 101, duration: 90, paused: true, rate: 2).position == 101)
        let invalidSession = PlaybackSessionSnapshot(position: .nan, duration: .infinity, paused: true, rate: -.infinity)
        check(invalidSession.position == 0 && invalidSession.duration == 0 && invalidSession.rate == 1 && invalidSession.paused)
        let primarySidecar = URL(fileURLWithPath: "/tmp/session-primary.srt")
        let selections = PlaybackSelectionSnapshot(embedded: ["audio": .embedded(ordinal: 1, count: 2), "sub": .off],
            primarySourceURL: primarySidecar,
            secondary: .init(selection: .embedded(ordinal: 0, count: 2), sourceURL: nil, descriptorID: nil))
        let selectedSession = PlaybackSessionSnapshot(position: 12.5, duration: 90, paused: true, rate: 1.75, selections: selections)
        check(selectedSession.replaying().selections == selections)
        check(selectedSession.replaying().rate == 1.75 && !selectedSession.replaying().paused)
        check(selectedSession.selections.audio?.resolve(embeddedIDs: [101, 204]) == 204)
        check(selectedSession.selections.audio?.resolve(embeddedIDs: [101]) == nil)
        check(selectedSession.selections.primary == .off && PlaybackSelectionSnapshot().primary == nil)
        check(selectedSession.selections.primarySourceURL == primarySidecar)
        check(selectedSession.selections.secondary?.resolve(candidates: [.init(id: "new", sourceURL: nil, nativeID: 31)], embeddedIDs: [31, 42]) == "new")
        for platform in [PlaybackPlatform.iOS, .macOS, .tvOS] {
            for engine in PlaybackEngineID.allCases {
                let capabilities = PlaybackEngineCapabilities(platform: platform, engine: engine)
                check(capabilities.metadataBackend == (engine == .mpv ? .independent : .vlc))
                check(capabilities.previewBackend == (engine == .mpv ? .independent : .vlc))
                for feature in PlaybackEngineCapabilities.Feature.allCases {
                    check(!capabilities.supports(feature, isVideo: false))
                    let expected = feature == .secondaryBitmap ? engine == .mpv : platform != .tvOS
                    check(capabilities.supports(feature, isVideo: true) == expected)
                }
            }
        }
        let observation = PlaybackTransportObservation()
        let activeState = PlaybackTransportState(phase: .playing, position: 25, duration: 90,
            seekable: true, audioTrackID: 5, subtitleTrackID: 8)
        observation.update(activeState)
        check(observation.snapshot == activeState)
        observation.fail()
        observation.update(activeState) // queued native clock after failure
        check(observation.snapshot.phase == .failed && !observation.snapshot.seekable)
        check(observation.snapshot.position == 25 && observation.snapshot.audioTrackID == 5)
        observation.stop()
        observation.update(activeState) // queued event after disposal
        check(observation.snapshot.phase == .idle && !observation.snapshot.seekable)
        let nextObservation = PlaybackTransportObservation()
        nextObservation.update(activeState)
        check(nextObservation.snapshot.phase == .playing)
        let iosCapabilities = PlaybackEngineCapabilities(platform: .iOS, engine: .mpv)
        let secureLive = URL(string: "rtsps://host/live")!
        check(macCapabilities.routingRestriction(url: secureLive, isVideo: true, isAudio: false) == nil)
        check(iosCapabilities.routingRestriction(url: secureLive, isVideo: true, isAudio: false) == .unsupportedProtocol)
        let localMovie = URL(fileURLWithPath: "/movie.mkv")
        check(macCapabilities.routingRestriction(url: localMovie, isVideo: true, isAudio: false, isVirtualMachine: true) == .virtualGPU)
        check(macCapabilities.routingRestriction(url: localMovie, isVideo: false, isAudio: true, isVirtualMachine: true) == nil)
        check(iosCapabilities.routingRestriction(url: localMovie, isVideo: true, isAudio: false, requiresVLCBridge: true) == .requiresVLCBridge)
        for invalidDuration in [0.0, -1, Double.nan, Double.infinity] {
            check(PlaybackEngineCapabilities.switchingRestriction(isPreparing: false, isStopped: false,
                hasFailed: false, isPictureInPicture: false, isLive: false,
                isSeekable: true, duration: invalidDuration) == .notSeekable)
        }
        check(PlaybackEngineCapabilities.switchingRestriction(isPreparing: false, isStopped: false,
            hasFailed: false, isPictureInPicture: false, isLive: true,
            isSeekable: true, duration: 100) == .live)
        check(PlaybackEngineCapabilities.switchingRestriction(isPreparing: false, isStopped: false,
            hasFailed: false, isPictureInPicture: true, isLive: false,
            isSeekable: true, duration: 100) == .pictureInPicture)
        check(PlaybackEngineCapabilities.switchingRestriction(isPreparing: false, isStopped: false,
            hasFailed: true, isPictureInPicture: false, isLive: false,
            isSeekable: true, duration: 100) == .failed)
        check(PlaybackEngineCapabilities.switchingRestriction(isPreparing: false, isStopped: false,
            hasFailed: false, isPictureInPicture: false, isLive: false,
            isSeekable: true, duration: 100) == nil)
        // Reopen the same container with completely different engine IDs.
        let handoff = IOSPlaybackTrackSelection.capture(id: 42, embeddedIDs: [12, 42, 71])!
        check(handoff.resolve(embeddedIDs: [1, 2, 3]) == 2)
        check(IOSPlaybackTrackSelection.capture(id: 2, embeddedIDs: [1, 2, 3])?.resolve(embeddedIDs: [12, 42, 71]) == 42)
        check(handoff.resolve(embeddedIDs: []) == nil) // tracks have not arrived
        check(handoff.resolve(embeddedIDs: [1, 2]) == nil) // changed container
        check(handoff.resolve(embeddedIDs: [1, 1, 3]) == nil)
        check(IOSPlaybackTrackSelection.capture(id: 99, embeddedIDs: [12, 42, 71]) == nil) // sidecar is not an ordinal
        check(IOSPlaybackTrackSelection.capture(id: 42, embeddedIDs: [42, 42]) == nil)
        check(IOSPlaybackTrackSelection.capture(id: -1, embeddedIDs: [12, 42])?.resolve(embeddedIDs: []) == -1)
        // A VLC sidecar can have a small native ID, alongside the synthetic menu IDs.
        let vlcSubtitleTracks: [(id: Int, isExternal: Bool)] = [(3, false), (4, false), (5, true), (10_000, true)]
        let secondEmbedded = IOSPlaybackTrackSelection.capture(id: 2, embeddedIDs: [1, 2])!
        check(secondEmbedded.resolve(embeddedIDs: vlcSubtitleTracks.map(\.id)) == nil)
        check(secondEmbedded.resolve(embeddedIDs: vlcSubtitleTracks.filter { !$0.isExternal }.map(\.id)) == 4)
        check(secondEmbedded.resolve(embeddedIDs: [3]) == nil) // wait for the remaining container track

        for (codec, format) in [("ASS", "ass"), (" ssa ", "ssa"), ("subrip", "srt"),
                                ("srt", "srt"), ("webvtt", "vtt"), ("vtt", "vtt"),
                                ("sup", "sup"), ("", "srt")] {
            check(TVMPVSubtitleLoader.fileExtension(forCodec: codec) == format)
        }
        check(TVMPVSubtitleLoader.fileExtension(forCodec: nil) == "srt")
        for scheme in ["smb", "ftp", "ftps", "sftp", "nfs"] {
            check(TVMPVSubtitleLoader.requiresDownload(URL(string: "\(scheme)://host/share/movie.en.srt")!))
        }
        for url in ["file:///movie.srt", "https://host/movie.srt", "http://host/movie.srt"] {
            check(!TVMPVSubtitleLoader.requiresDownload(URL(string: url)!))
        }
        let subtitleData = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
        var subtitleReads: [(UInt64, Int)] = []
        let loadedSubtitle = try await TVMPVSubtitleLoader.load(size: UInt64(subtitleData.count)) { offset, count in
            subtitleReads.append((offset, count))
            return subtitleData.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        check(loadedSubtitle == subtitleData)
        check(subtitleReads.count == 3 && subtitleReads[2].0 == 2 * 1024 * 1024 && subtitleReads[2].1 == 17)
        check(subtitleReads.allSatisfy { $0.1 <= 1024 * 1024 })
        for size in [UInt64(0), TVMPVSubtitleLoader.maximumBytes + 1, UInt64.max] {
            do {
                _ = try await TVMPVSubtitleLoader.load(size: size) { _, _ in preconditionFailure("invalid size must not read") }
                check(false)
            } catch TVMPVSubtitleLoader.Failure.sizeLimit { check(true) }
        }
        for returnedCount in [0, 1, 5] {
            do {
                _ = try await TVMPVSubtitleLoader.load(size: 4) { _, _ in Data(repeating: 1, count: returnedCount) }
                check(false)
            } catch TVMPVSubtitleLoader.Failure.incompleteRead { check(true) }
        }
        // Cancellation during a reader that ignores cancellation must still reject its bytes.
        let cancelledSubtitle = Task {
            try await TVMPVSubtitleLoader.load(size: 4) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Data(repeating: 1, count: 4)
            }
        }
        do { _ = try await cancelledSubtitle.value; check(false) }
        catch is CancellationError { check(true) }
        func scope(_ url: String, provider: String? = nil, server: String? = nil,
                   series: String? = nil, path: String? = nil, item: String? = nil) -> String? {
            IOSPlaybackTrackSelection.scopeKey(url: URL(string: url)!, provider: provider,
                serverID: server, seriesID: series, filePath: path, libraryItemID: item)
        }
        check(scope("file:///movies/A/1.mkv") == scope("file:///movies/A/2.mkv"))
        check(scope("file:///movies/A/1.mkv") != scope("file:///movies/B/1.mkv"))
        check(scope("https://host/Videos/one/stream") == nil)
        check(scope("file:///downloads/movie.mkv", provider: "jellyfin", server: "A", item: "movie") == nil)
        let seriesScope = scope("https://host/a?token=secret", provider: "jellyfin", server: "A", series: "show", item: "one")!
        check(seriesScope == scope("https://other/b?token=rotated", provider: "jellyfin", server: "A", series: "show", item: "two"))
        check(seriesScope != scope("https://host/a", provider: "jellyfin", server: "B", series: "show", item: "one"))
        check(seriesScope != scope("https://host/a", provider: "jellyfin", server: "A", series: "other", item: "one"))
        check(!seriesScope.contains("secret") && !seriesScope.contains("host"))
        check(scope("https://host/a", provider: "jellyfin", server: "A", path: "/movies/a.mkv", item: "movie") == nil)
        let directoryScope = scope("https://host/a", provider: "webdav", server: "A", path: "/series/1.mkv")!
        check(directoryScope == scope("https://host/b", provider: "webdav", server: "A", path: "/series/2.mkv"))
        check(directoryScope != scope("https://host/b", provider: "webdav", server: "B", path: "/series/2.mkv"))
        check(scope("https://host/a", provider: "webdav", server: "A", path: "relative.mkv") == nil)
        // Read the shipped font's actual metrics; no player or GUI is started.
        let fontURL = URL(fileURLWithPath: "GenPlayer/Source/Resources/Fonts/SourceHanSansSC-Regular.otf")
        let typography = IOSSubtitleTypography(fontURL: fontURL)
        check(typography.fontFamily == "Source Han Sans SC")
        check(abs(typography.assHeightToEMRatio - 1.48) < 0.0001)
        let registeredAgain = IOSSubtitleTypography(fontURL: fontURL)
        check(registeredAgain.fontFamily == typography.fontFamily)
        check(registeredAgain.assHeightToEMRatio == typography.assHeightToEMRatio)
        // At 720 video pixels, iPad's VLC divisor 22 means 32.727 EM pixels,
        // or 48.436 libass real-dimension pixels for the bundled font.
        check(abs(typography.mpvFontSize(vlcRelativeDivisor: 22) - 48.4363636364) < 0.0001)
        for divisor in [17.0, 20, 22] {
            for videoHeight in [280.0, 580, 720, 1080, 2016] {
                let assSize = typography.mpvFontSize(vlcRelativeDivisor: divisor) * videoHeight / 720
                check(abs(assSize / typography.assHeightToEMRatio - videoHeight / divisor) < 0.0001)
            }
        }
        for invalid in [0.0, -1, .nan, .infinity] {
            check(typography.mpvFontSize(vlcRelativeDivisor: invalid) == typography.mpvFontSize(vlcRelativeDivisor: 22))
        }
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920),
                     CGSize(width: 640, height: 640)] {
            let assSize = typography.mpvFontSize(vlcRelativeDivisor: 22, videoSize: size) * size.height / 720
            check(abs(assSize / typography.assHeightToEMRatio - min(size.width, size.height) / 22) < 0.0001)
        }
        check(IOSSubtitleTypography(fontURL: nil).mpvFontSize(vlcRelativeDivisor: 22).isFinite)
        // A no-Lua build can omit disabling switches, but an enable request or
        // missing renderer/decoder/network option must never become a success.
        for name in MPVStartupOptionPolicy.disabledScripts.keys {
            check(MPVStartupOptionPolicy.acceptsMissingOption(name: name, value: "no"))
            check(!MPVStartupOptionPolicy.acceptsMissingOption(name: name, value: "yes"))
            check(!MPVStartupOptionPolicy.acceptsMissingOption(name: name, value: "auto"))
        }
        for name in ["vo", "gpu-context", "hwdec", "http-header-fields", "load-consol"] {
            check(!MPVStartupOptionPolicy.acceptsMissingOption(name: name, value: "no"))
        }
        func supported(_ scheme: String, video: Bool = true, live: Bool = false,
                       bridge: Bool = false, vm: Bool = false) -> Bool {
            MacMPVPlaybackPolicy.supports(url: URL(string: "\(scheme)://fixture.invalid/movie.mkv")!,
                isVideo: video, isLive: live, requiresVLCBridge: bridge, isVirtualMachine: vm)
        }
        // Both media types route independently; PiP still explicitly requires VLC.
        for scheme in ["file", "http", "https", "smb", "ftp", "ftps", "sftp", "nfs", "rtsp", "rtp", "udp", "unknown"] {
            let url = URL(string: "\(scheme)://fixture.invalid/video.mkv")!
            check(MPVUIKitPlaybackPolicy.supports(url: url, isVideo: true, requiresVLCBridge: false)
                  == ["file", "http", "https", "smb", "ftp", "ftps", "sftp", "nfs", "rtsp", "rtp", "udp"].contains(scheme))
            check(!MPVUIKitPlaybackPolicy.supports(url: url, isVideo: false, requiresVLCBridge: false))
            check(MPVUIKitPlaybackPolicy.supports(url: url, isVideo: false, isAudio: true, requiresVLCBridge: false) == (scheme != "unknown"))
            check(!MPVUIKitPlaybackPolicy.supports(url: url, isVideo: false, isAudio: true, requiresVLCBridge: true))
            check(!MPVUIKitPlaybackPolicy.supports(url: url, isVideo: true, requiresVLCBridge: true))

        }
        // TV supports audio and video with the same independent NAS range readers.
        for scheme in ["file", "http", "https", "smb", "ftp", "ftps", "sftp", "nfs", "rtsp", "rtp", "udp", "unknown"] {
            let url = URL(string: "\(scheme)://fixture.invalid/video.mkv")!
            check(TVMPVPlaybackPolicy.supports(url: url, isVideo: true) == ["file", "http", "https", "smb", "ftp", "ftps", "sftp", "nfs", "rtsp", "rtp", "udp"].contains(scheme))
            check(!TVMPVPlaybackPolicy.supports(url: url, isVideo: false))
            check(TVMPVPlaybackPolicy.supports(url: url, isVideo: false, isAudio: true) == (scheme != "unknown"))
        }
        for codec in ["subrip", "ASS", "ssa", "webvtt", "mov_text", "tx3g"] {
            check(TVMPVPlaybackPolicy.supportsText(codec))
        }
        for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "unknown", ""] {
            check(!TVMPVPlaybackPolicy.supportsText(codec))
        }
        let videoOptions = ["vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk",
                            "target-colorspace-hint": "yes", "vid": "auto", "sid": "auto", "speed": "1.5", "pause": "yes"]
        check(MPVStartupOptionPolicy.renderingOptions(videoOptions, audioOnly: false) == videoOptions)
        let audioOptions = MPVStartupOptionPolicy.renderingOptions(videoOptions, audioOnly: true)
        for key in ["vid", "sid", "secondary-sid"] { check(audioOptions[key] == "no") }
        check(audioOptions["vo"] == "null")
        for key in ["gpu-api", "gpu-context", "target-colorspace-hint"] { check(audioOptions[key] == nil) }
        check(audioOptions["pause"] == "yes" && audioOptions["speed"] == "1.5")
        // Invalid layout sizes must not allocate; cap pixel budget across rotations/Retina.
        for size in [CGSize.zero, CGSize(width: -1, height: 400), CGSize(width: CGFloat.infinity, height: 10),
                     CGSize(width: 10, height: CGFloat.nan)] {
            check(MPVSoftwareRenderSize.fit(size) == nil)
        }
        for size in [CGSize(width: 1640, height: 2360), CGSize(width: 2360, height: 1640),
                     CGSize(width: 7680, height: 4320), CGSize(width: 640, height: 360),
                     CGSize(width: 1e20, height: 1e20)] {
            let fit = MPVSoftwareRenderSize.fit(size)!
            check(max(fit.width, fit.height) <= 1280)
            check(fit.width >= 2 && fit.height >= 2)
            check(abs(fit.width / fit.height - size.width / size.height) < 0.005)
            check(((Int(fit.width) * 4 + 63) & ~63) * Int(fit.height) <= 1280 * 1280 * 4)
        }
        check(MPVSoftwareRenderSize.fit(CGSize(width: 640, height: 360)) == CGSize(width: 640, height: 360))
        // TV subtitles are rasterized at 1080p rather than a 720p preview.
        check(MPVSoftwareRenderSize.fit(CGSize(width: 1920, height: 1080), maximumDimension: 1920) == CGSize(width: 1920, height: 1080))
        check(MPVSoftwareRenderSize.fit(CGSize(width: 3840, height: 2160), maximumDimension: 1920) == CGSize(width: 1920, height: 1080))
        check(MPVSoftwareRenderSize.fit(CGSize(width: 640, height: 360), maximumDimension: 1920) == CGSize(width: 640, height: 360))
        check(MPVSoftwareRenderSize.fit(CGSize(width: 1920, height: 1080), maximumDimension: .nan) == nil)
        check(TVMPVPlaybackPolicy.secondarySubtitlePosition(customPosition: nil) == 0.84)
        for position in [0.08, 0.7, 0.92] {
            check(TVMPVPlaybackPolicy.secondarySubtitlePosition(customPosition: position) == position)
        }
        for scheme in ["file", "http", "https"] { check(supported(scheme)) }
        for scheme in ["smb", "ftp", "ftps", "sftp", "nfs"] { check(supported(scheme)) }
        for scheme in ["rtsp", "rtsps", "rtp", "udp"] {
            check(supported(scheme, live: true))
            check(MacMPVPlaybackPolicy.isLiveProtocol(URL(string: "\(scheme)://fixture.invalid/live")!))
        }
        check(!supported("unknown"))
        check(supported("https", video: false))
        check(supported("file", video: false, vm: true))
        check(supported("https", live: true))
        check(!supported("file", bridge: true))
        check(!supported("file", vm: true))
        check(MacMPVPlaybackPolicy.milliseconds(.nan) == 0)
        check(MacMPVPlaybackPolicy.milliseconds(.infinity) == 0)
        check(MacMPVPlaybackPolicy.milliseconds(-8) == 0)
        check(MacMPVPlaybackPolicy.milliseconds(123.5) == 123_500)
        check(MacMPVPlaybackPolicy.milliseconds(1e100) == Int32.max)
        func track(_ id: Int, title: String = "English", lang: String = "eng", codec: String = "subrip", external: String? = nil) -> MacMPVTrack {
            MacMPVTrack(id: id, type: "sub", title: title, language: lang, codec: codec,
                        external: external != nil, externalFilename: external ?? "")
        }
        let a = track(2), b = track(7, title: "中文", lang: "zho")
        var remoteA = a, remoteB = b
        remoteA.sourceID = 5; remoteB.sourceID = 9
        let remoteSidecar = track(100, external: "/tmp/sidecar.srt")
        let remoteAudio = MacMPVTrack(id: 2, type: "audio", title: "Audio", language: "en", codec: "aac", external: false)
        let remoteTracks = [remoteAudio, remoteA, remoteSidecar, remoteB]
        let remoteSelection = IOSMPVRemoteSubtitleSelection(selectedID: 7, tracks: remoteTracks)!
        check(remoteSelection.ordinal == 1 && remoteSelection.count == 2 && remoteSelection.trackNumbers == [5, 9])
        check(IOSMPVRemoteSubtitleSelection.nativeTracks(in: remoteTracks).map(\.id) == [2, 7])
        check(IOSMPVRemoteSubtitleSelection(selectedID: 100, tracks: remoteTracks) == nil)
        check(IOSMPVRemoteSubtitleSelection(selectedID: -1, tracks: remoteTracks) == nil)
        check(IOSMPVRemoteSubtitleSelection(selectedID: 7, tracks: [remoteB, remoteA])?.ordinal == 0)
        check(IOSMPVRemoteSubtitleSelection(selectedID: 7, tracks: [remoteB, remoteA]) != remoteSelection)
        check(IOSMPVRemoteSubtitleSelection(selectedID: 7, tracks: [remoteA, b]) == nil)
        var duplicateNumber = remoteB; duplicateNumber.sourceID = 5
        check(IOSMPVRemoteSubtitleSelection.nativeTracks(in: [remoteA, duplicateNumber]).isEmpty)
        var duplicateID = remoteA; duplicateID.sourceID = 9
        check(IOSMPVRemoteSubtitleSelection.nativeTracks(in: [remoteA, duplicateID]).isEmpty)
        var zeroNumber = remoteB; zeroNumber.sourceID = 0
        check(IOSMPVRemoteSubtitleSelection.nativeTracks(in: [remoteA, zeroNumber]).isEmpty)
        for codec in ["subrip", "srt", "ASS", "ssa", "webvtt"] {
            check(IOSMPVRemoteSubtitleSelection.supportsText(codec: codec))
        }
        for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "unknown", ""] {
            check(!IOSMPVRemoteSubtitleSelection.supportsText(codec: codec))
        }
        let independentChoices = ["sub": MacMPVTrackChoice.selected(2, in: [remoteA, remoteB])!,
                                  "secondary": MacMPVTrackChoice.selected(7, in: [remoteA, remoteB])!]
        let restoredChoices = try JSONDecoder().decode([String: MacMPVTrackChoice].self, from: JSONEncoder().encode(independentChoices))
        check(restoredChoices["sub"]?.resolve(in: [remoteA, remoteB]) == 2)
        check(restoredChoices["secondary"]?.resolve(in: [track(12), track(17, title: "中文", lang: "zho")]) == 17)
        check(restoredChoices["secondary"]?.resolve(in: [remoteA]) == nil)
        check(IOSMPVRemoteSubtitleSelection.menuID(trackID: 7) == -1_000_007)
        check(IOSMPVRemoteSubtitleSelection.trackID(menuID: -1_000_007) == 7)
        for id in [-1, -900002, -900003, -900004, 20_000, Int.min, Int.max] {
            check(IOSMPVRemoteSubtitleSelection.trackID(menuID: id) == nil)
        }
        check(IOSMPVRemoteSubtitleSelection.menuID(trackID: -1) == nil)
        check(IOSMPVRemoteSubtitleSelection.menuID(trackID: Int.max) == nil)
        // Simulate mpv's refusal to select a track already owned by the other
        // slot. Exercise both directions, same-source routing, swaps and Off.
        for initial in [(2, 7), (7, 2), (2, -1), (-1, 7)] {
            for target in [(2, 2), (7, 7), (7, 2), (2, 7), (-1, 7), (2, -1), (-1, -1)] {
                var primary = initial.0, secondary = initial.1
                for (property, value) in MacMPVSubtitleSelection.operations(primary: target.0, secondary: target.1) {
                    let id = Int(value) ?? -1
                    if property == "sid" {
                        check(id < 0 || id != secondary)
                        primary = id
                    } else {
                        check(id < 0 || id != primary)
                        secondary = id
                    }
                }
                check(primary == target.0)
                check(secondary == (target.0 == target.1 ? -1 : target.1))
            }
        }
        let choice = MacMPVTrackChoice.selected(7, in: [a,b])!
        check(choice.resolve(in: [track(99), track(11, title: "中文", lang: "zho")]) == 11)
        check(choice.resolve(in: [a]) == nil)
        let encoded = try! JSONEncoder().encode(choice)
        check(try! JSONDecoder().decode(MacMPVTrackChoice.self, from: encoded) == choice)
        check(!String(data: encoded, encoding: .utf8)!.contains("\"id\""))
        check(MacMPVTrackChoice.selected(-1, in: [])!.resolve(in: [a,b]) == -1)
        check(MacMPVTrackChoice.selected(777, in: [a,b]) == nil)
        let duplicate = MacMPVTrackChoice.selected(3, in: [a,track(3)])!
        check(duplicate.resolve(in: [track(5),track(9)]) == 9)
        check(duplicate.resolve(in: [track(5)]) == nil) // ambiguous changed track set
        let sidecar = track(8, external: "/tmp/movie sub.srt")
        check(sidecar.externalURL?.path == "/tmp/movie sub.srt")
        check(MacMPVTrackChoice.selected(8, in: [a,sidecar])!.resolve(in: [a]) == nil)
        check(track(1, external: "https://example.invalid/sub.srt").externalURL?.scheme == "https")
        check(track(1, external: "unsupported://fixture").externalURL == nil)
        check(track(1, codec: "hdmv_pgs_subtitle").isBitmap)
        check(!a.isBitmap)
        let u1 = URL(string: "https://user:secret@example.invalid/watch?id=1&api_key=old")!
        let u2 = URL(string: "https://other:new@example.invalid/watch?api_key=new&id=1")!
        let key = MacMPVTrackChoice.mediaKey(url: u1)
        check(key == MacMPVTrackChoice.mediaKey(url: u2))
        check(!key.contains("secret") && !key.contains("example"))
        check(key != MacMPVTrackChoice.mediaKey(url: URL(string: "https://example.invalid/watch?id=2")!))
        check(MacMPVTrackChoice.mediaKey(url: u1, serverID: "A", itemID: "item") ==
              MacMPVTrackChoice.mediaKey(url: u2, serverID: "A", itemID: "item"))
        check(MacMPVTrackChoice.mediaKey(url: u1, serverID: "A", itemID: "item") !=
              MacMPVTrackChoice.mediaKey(url: u1, serverID: "B", itemID: "item"))
        let descriptors: [(String?, String?, String?)] = [("srt","en","English"),("subrip","chi","中文")]
        check(MacMPVSubtitleMapping.ordinal(selectedID: 7, tracks: [a,b,sidecar], descriptors: descriptors) == 1)
        check(MacMPVSubtitleMapping.ordinal(selectedID: 8, tracks: [a,b,sidecar], descriptors: descriptors) == nil)
        check(MacMPVSubtitleMapping.ordinal(selectedID: 7, tracks: [a,b], descriptors: Array(descriptors.reversed())) == nil)
        check(MacMPVSubtitleMapping.ordinal(selectedID: 2, tracks: [a,b], descriptors: [("srt","en","English")]) == nil)
        check(MacMPVSubtitleMapping.ordinal(selectedID: 2, tracks: [a,a], descriptors: descriptors) == nil)
        check(MacMPVSubtitleMapping.ordinal(selectedID: 2, tracks: [a], descriptors: [("ass","en","English")]) == nil)
        let audioA = MacMPVTrack(id: 1, type: "audio", title: "", language: "eng", codec: "aac", external: false)
        let audioB = MacMPVTrack(id: 2, type: "audio", title: "", language: "zho", codec: "ac3", external: false)
        check(MacMPVAudioMapping.remuxSelection(selectedID: 2, tracks: [a, audioA, audioB], source: [(7, 1), (1, 2)]) == 1)
        check(MacMPVAudioMapping.remuxSelection(selectedID: 1, tracks: [audioA, audioB], source: [(1, 2), (7, 1)]) == 7)
        check(MacMPVAudioMapping.remuxSelection(selectedID: 2, tracks: [audioA, audioB], source: [(7, 1)]) == nil)
        check(MacMPVAudioMapping.remuxSelection(selectedID: 2, tracks: [audioA, audioB], source: [(7, 1), (8, 1)]) == nil)
        check(MacMPVAudioMapping.remuxSelection(selectedID: -1, tracks: [audioA, audioB], source: [(7, 1), (8, 2)]) == nil)
        check(MacMPVAudioMapping.remuxSelection(selectedID: 2, tracks: [], source: []) == nil)
        check(track(8, external: "smb://fixture.invalid/sub.srt").externalURL?.scheme == "smb")
        check(MacMPVMediaSourceSelection.index(requestedID: "B", sourceIDs: ["A", "B"]) == 1)
        check(MacMPVMediaSourceSelection.index(requestedID: nil, sourceIDs: ["A", "B"]) == nil)
        check(MacMPVMediaSourceSelection.index(requestedID: "C", sourceIDs: ["A", "B"]) == nil)
        check(MacMPVMediaSourceSelection.index(requestedID: "A", sourceIDs: ["A", "A"]) == nil)
        check(MacMPVMediaSourceSelection.index(requestedID: nil, sourceIDs: ["A"]) == 0)
        check(MacMPVMediaSourceSelection.index(requestedID: nil, sourceIDs: []) == nil)
        var decoded = MacMPVDecodedSubtitles()
        decoded.select("session-a|track-3")
        decoded.append(text: "First", start: 12, end: 14)
        decoded.append(text: "First", start: 12, end: 14)
        check(decoded.cues.count == 1) // Repeated polls and paused frames must not duplicate lines.
        let stableID = decoded.cues[0].id
        decoded.append(text: "Earlier after seek", start: 2, end: 3)
        check(decoded.cues.map(\.start) == [2, 12])
        check(decoded.cues.last?.id == stableID)
        check(decoded.activeCues(at: 12).first?.id == stableID)
        check(decoded.activeCues(at: 14).isEmpty)
        check(decoded.activeCues(at: 12 - 2).isEmpty) // independent positive delay
        check(decoded.activeCues(at: 10 - (-2)).first?.id == stableID)
        check(decoded.activeCues(at: 2).first?.text == "Earlier after seek")
        decoded.append(text: "", start: 14, end: 15)
        decoded.append(text: "bad", start: .nan, end: 10)
        decoded.append(text: "missing timing", start: nil, end: nil)
        decoded.append(text: "backwards", start: 9, end: 8)
        check(decoded.cues.count == 2)
        decoded.select("session-a|track-3")
        check(decoded.cues.count == 2)
        decoded.select("session-a|track-4")
        check(decoded.cues.isEmpty)
        decoded.append(text: "Other track", start: 12, end: 14)
        check(decoded.cues.first?.text == "Other track")
        decoded.select("session-b|track-4")
        check(decoded.cues.isEmpty)
        for i in 0..<2010 { decoded.append(text: "Line \(i)", start: Double(i), end: Double(i + 1)) }
        check(decoded.cues.count == 2000)
        check(Set(decoded.cues.map(\.id)).count == 2000)
        var limited = MacMPVDecodedSubtitles(maximumTextBytes: 8)
        limited.select("ios-track")
        limited.append(text: "12345", start: 1, end: 2)
        let revision = limited.revision
        limited.append(text: "12345", start: 1, end: 2)
        check(limited.revision == revision)
        limited.append(text: "67890", start: 3, end: 4)
        check(limited.cues.map(\.text) == ["67890"])
        check(limited.revision > revision)
        limited.append(text: "oversized", start: 5, end: 6)
        check(limited.cues.map(\.text) == ["67890"])
        limited.select("other-track")
        limited.append(text: "12345678", start: 0, end: 1)
        check(limited.cues.count == 1)
        // Main and secondary decoders have separate bounded transcripts, even at identical timestamps.
        var second = MacMPVDecodedSubtitles(maximumTextBytes: 32)
        second.select("movie|secondary|9")
        second.append(text: "Secondary", start: 10.25, end: 12.5)
        var main = MacMPVDecodedSubtitles(maximumTextBytes: 32)
        main.select("movie|primary|2")
        main.append(text: "Primary", start: 10.25, end: 12.5)
        check(second.activeCues(at: 10.25).first?.text == "Secondary")
        check(main.activeCues(at: 10.25).first?.text == "Primary")
        check(second.activeCues(at: 12.5).isEmpty)
        // Delay sign remains the existing iOS time+delay contract, including fractional cues.
        check(second.activeCues(at: 9.5 + 1).first?.text == "Secondary")
        check(second.activeCues(at: 11.5 - 1).first?.text == "Secondary")
        second.select("movie|secondary|10")
        check(second.cues.isEmpty && !main.cues.isEmpty)
        second.select("movie|secondary|9")
        check(second.cues.isEmpty)
        second.append(text: "Replayed", start: 10.25, end: 12.5)
        second.select("")
        check(second.cues.isEmpty)
        let noSourceID = [MacMPVTrack(id: 7, type: "sub", title: "Text", language: "en", codec: "mov_text", external: false)]
        check(IOSMPVRemoteSubtitleSelection.nativeTracks(in: noSourceID).isEmpty)
        check(IOSMPVRemoteSubtitleSelection.playbackTracks(in: noSourceID).map(\.id) == [7])
        check(IOSMPVRemoteSubtitleSelection.playbackTracks(in: noSourceID + noSourceID).isEmpty)
        for codec in ["mov_text", "tx3g", "text", "subrip", "ASS", "webvtt"] {
            check(IOSMPVRemoteSubtitleSelection.supportsText(codec: codec))
        }
        for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "unknown"] {
            check(!IOSMPVRemoteSubtitleSelection.supportsText(codec: codec))
        }
        let secondaryHandoff = IOSPlaybackSecondarySelection(selection: .embedded(ordinal: 1, count: 2), sourceURL: nil, descriptorID: "old-id")
        let newCandidates: [IOSPlaybackSecondarySelection.Candidate] = [
            .init(id: "new-a", sourceURL: nil, nativeID: 30), .init(id: "new-b", sourceURL: nil, nativeID: 42)]
        check(secondaryHandoff.resolve(candidates: newCandidates, embeddedIDs: [30, 42]) == "new-b")
        check(secondaryHandoff.resolve(candidates: newCandidates, embeddedIDs: [30]) == nil)
        check(secondaryHandoff.resolve(candidates: [.init(id: "old-id", sourceURL: nil, nativeID: 30)], embeddedIDs: [30]) == nil)
        check(secondaryHandoff.resolve(candidates: newCandidates, embeddedIDs: [30, 30]) == nil)
        let subtitleURL = URL(string: "smb://fixture.invalid/share/movie.en.srt")!
        let externalChoice = IOSPlaybackSecondarySelection(selection: nil, sourceURL: subtitleURL, descriptorID: nil)
        check(externalChoice.resolve(candidates: [.init(id: "external", sourceURL: subtitleURL, nativeID: 99)], embeddedIDs: []) == "external")
        check(externalChoice.resolve(candidates: newCandidates, embeddedIDs: [30, 42]) == nil)
        // Same ASS track survives native-ID changes across mpv -> VLC -> mpv.
        let mpvASS = IOSPlaybackSecondarySelection(selection: .embedded(ordinal: 1, count: 3), sourceURL: nil, descriptorID: "mpv-7")
        let vlcCandidates: [IOSPlaybackSecondarySelection.Candidate] = [
            .init(id: "vlc-ass", sourceURL: nil, nativeID: 51),
            .init(id: "external-collision", sourceURL: subtitleURL, nativeID: 7)]
        check(mpvASS.resolve(candidates: vlcCandidates, embeddedIDs: [50, 51, 52]) == "vlc-ass")
        let returnASS = IOSPlaybackSecondarySelection(selection: IOSPlaybackTrackSelection.capture(id: 51, embeddedIDs: [50, 51, 52]), sourceURL: nil, descriptorID: "vlc-ass")
        check(returnASS.resolve(candidates: [.init(id: "mpv-107", sourceURL: nil, nativeID: 107)], embeddedIDs: [100, 107, 112]) == "mpv-107")
        check(mpvASS.resolve(candidates: [], embeddedIDs: [50, 51, 52]) == nil) // Keep intent if VLC cannot read this source.
        check(mpvASS.resolve(candidates: [.init(id: "mpv-7", sourceURL: nil, nativeID: 7)], embeddedIDs: [1, 7, 8]) == "mpv-7")
        for primaryDelay in [-2.0, 0, 1.25] {
            for secondaryDelay in [-1.5, 0, 3.0] {
                let legacyVLCTime = 20 + primaryDelay + secondaryDelay
                let mpvTime = 20 - MPVSecondarySubtitleRendering.nativeDelay(primary: primaryDelay, secondary: secondaryDelay)
                let mirrorTime = MPVSecondarySubtitleRendering.sourceTime(playbackTime: 20, primary: primaryDelay, secondary: secondaryDelay)
                check(mpvTime == legacyVLCTime && mirrorTime == legacyVLCTime)
                let cueStart = legacyVLCTime
                let browserSeek = cueStart + MPVSecondarySubtitleRendering.nativeDelay(primary: primaryDelay, secondary: secondaryDelay)
                check(browserSeek == 20)
            }
        }
        let disabledSecondary = IOSPlaybackSecondarySelection(selection: .off, sourceURL: subtitleURL, descriptorID: "new-a")
        check(disabledSecondary.resolve(candidates: newCandidates, embeddedIDs: [30, 42]) == nil)
        let serverChoice = IOSPlaybackSecondarySelection(selection: nil, sourceURL: nil, descriptorID: "server-3")
        check(serverChoice.resolve(candidates: [.init(id: "server-3", sourceURL: nil, nativeID: nil)], embeddedIDs: []) == "server-3")
        // Synthetic pixels only: verifies RGBA channel order, alpha and padded row strides.
        let pixels = Data([255,0,0,255, 0,255,0,255, 9,9,9,9,
                           0,0,255,255, 255,255,255,255, 9,9,9,9])
        let frame = MacMPVCaptureFrame(width: 2, height: 2, stride: 12, pixels: pixels)!
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-capture-fixture-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: png) }
        check(frame.writePNG(to: png))
        let rep = NSBitmapImageRep(data: try! Data(contentsOf: png))!
        check(rep.pixelsWide == 2 && rep.pixelsHigh == 2)
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            var values = [Int](repeating: 0, count: 4)
            rep.getPixel(&values, atX: x, y: y)
            return values
        }
        check(pixel(0, 0) == [255, 0, 0, 255])
        check(pixel(1, 0) == [0, 255, 0, 255])
        check(pixel(0, 1) == [0, 0, 255, 255])
        check(MacMPVCaptureFrame(width: 2, height: 2, stride: 7, pixels: pixels) == nil)
        check(MacMPVCaptureFrame(width: 2, height: 2, stride: 16, pixels: pixels) == nil)
        check(MacMPVCaptureFrame(width: Int.max, height: 2, stride: 8, pixels: pixels) == nil)
        check(MacMPVCaptureFrame(width: 2, height: 0, stride: 8, pixels: pixels) == nil)
        // Exercise the production blocking/async boundary without libmpv, files or network.
        let payload = Data((0..<1_100_000).map { UInt8($0 % 251) })
        let stream = MacMPVStream(metadata: { UInt64(payload.count) }, read: { start, size in
            payload.subdata(in: Int(start)..<(Int(start) + size))
        })
        check(stream.open())
        check(!stream.open())
        var output = [UInt8](repeating: 0, count: 4096)
        func read(_ source: MacMPVStream, count: UInt64 = 4096) -> Int64 {
            output.withUnsafeMutableBytes { source.read(into: $0.baseAddress!, count: count) }
        }
        check(read(stream) == 4096)
        check(Data(output) == payload.prefix(4096))
        check(stream.seek(1_047_552) == 1_047_552)
        check(read(stream) == 1024) // Short read at the cached block boundary.
        check(Data(output.prefix(1024)) == payload.subdata(in: 1_047_552..<1_048_576))
        check(read(stream) == 4096)
        check(Data(output) == payload.subdata(in: 1_048_576..<1_052_672))
        check(stream.seek(3) == 3)
        check(read(stream) == 4096)
        check(Data(output) == payload.subdata(in: 3..<4099))
        check(stream.seek(Int64(payload.count) - 7) == Int64(payload.count) - 7)
        check(read(stream) == 7)
        check(Data(output.prefix(7)) == payload.suffix(7))
        check(read(stream) == 0)
        check(stream.seek(-1) == -1)
        check(stream.seek(Int64(payload.count) + 1) == -1)
        stream.cancel(); stream.cancel()
        check(stream.seek(0) == -1)
        check(read(stream) == -1)
        let cancelledOpen = MacMPVStream(metadata: { 10 }, read: { _, _ in Data() })
        cancelledOpen.cancel(); check(!cancelledOpen.open())
        let oversized = MacMPVStream(metadata: { UInt64.max }, read: { _, _ in Data() })
        check(!oversized.open())
        let truncated = MacMPVStream(metadata: { 10 }, read: { _, _ in Data([1]) })
        check(truncated.open()); check(read(truncated) == -1)
        let interrupted = MacMPVStream(metadata: { 10 }, read: { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return Data(repeating: 1, count: 10)
        })
        check(interrupted.open())
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { interrupted.cancel() }
        let started = Date()
        check(read(interrupted) == -1)
        check(Date().timeIntervalSince(started) < 2)
        let interruptedMetadata = MacMPVStream(metadata: {
            try await Task.sleep(nanoseconds: 10_000_000_000); return 10
        }, read: { _, _ in Data() })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { interruptedMetadata.cancel() }
        check(!interruptedMetadata.open())
        print("PASS: \(count) macOS mpv routing, track identity, credential isolation, subtitle mapping, decoded cues, PNG pixels and cancellable stream checks (no app or media opened)")
    }
}
