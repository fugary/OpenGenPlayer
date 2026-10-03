import Foundation
import GenPlayerCore

@main
struct SubtitleBrowserChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func part(_ start: Double, _ end: Double, _ text: String) -> SubtitlePart {
        SubtitlePart(start: start, end: end, text: NSAttributedString(string: text))
    }

    @MainActor static func main() async throws {
        try await checkLocalTracks()
        try await checkRemoteReader()
        let document = SubtitleBrowserDocument(parts: [
            part(12, 14, "Back to the station."), part(10, 12, "<i>Café</i> &amp; 茶"),
            part(11, 13, "Overlapping dialogue"), part(20, 22, "车站到了"),
            part(.nan, 25, "invalid"), part(3, .infinity, "invalid"),
            part(1, 1, "empty duration"), part(1, 2, "{\\an8}<b></b>")
        ])
        expect(document.entries.count == 4, "Exclude invalid timing, tags-only and empty text")
        expect(document.entries[0].text == "Café & 茶", "Clean subtitle markup and entities")
        expect(document.matching(" CAFE ").count == 1, "Case, accents and query whitespace")
        expect(document.matching("车站").count == 1, "CJK substring search")
        expect(document.matching("missing").isEmpty, "No false matches")
        expect(document.matching("   ") == document.entries, "Empty query restores all lines")
        expect(document.activeIDs(at: 9, offset: 0).isEmpty, "No highlight before first cue")
        expect(document.activeIDs(at: 10, offset: 0) == [document.entries[0].id], "Start boundary included")
        expect(document.activeIDs(at: 11.5, offset: 0).count == 2, "Overlapping cues highlighted")
        expect(!document.activeIDs(at: 12, offset: 0).contains(document.entries[0].id), "End boundary excluded")
        expect(document.activeIDs(at: 17, offset: 0).isEmpty, "Dialogue gaps are not highlighted")
        expect(document.activeIDs(at: 12, offset: 2) == [document.entries[0].id], "Positive display delay")
        expect(document.activeIDs(at: 8, offset: -2) == [document.entries[0].id], "Negative display delay")
        expect(document.activeIDs(at: .nan, offset: 0).isEmpty, "Invalid clock ignored")
        expect(document.anchorID(at: 0, offset: 0) == document.entries.first?.id, "Before first cue anchors first")
        expect(document.anchorID(at: 17, offset: 0) == document.entries[2].id, "Gap anchors preceding dialogue")
        expect(document.anchorID(at: 99, offset: 0) == document.entries.last?.id, "After last cue anchors last")
        expect(SubtitleBrowserDocument.seekTime(for: document.entries[0], offset: 2) == 12, "Seek matches positive display delay")
        expect(SubtitleBrowserDocument.seekTime(for: document.entries[0], offset: -20) == 0, "Seek clamps at media start")
        let earlier = SubtitleBrowserDocument(parts: [part(1, 2, "new earlier chunk"), part(10, 12, "updated translation")])
        expect(earlier.entries[1].id == document.entries[0].id, "Earlier chunks and text updates preserve row identity")
        let duplicates = SubtitleBrowserDocument(parts: [part(1, 2, "first"), part(1, 2, "second")])
        expect(Set(duplicates.entries.map(\.id)).count == 2, "Coincident cues have unique IDs")
        let longOverlap = SubtitleBrowserDocument(parts: [part(1, 100, "long"), part(2, 3, "short"), part(4, 5, "short")])
        expect(longOverlap.activeIDs(at: 50, offset: 0).count == 1, "Long overlap survives expired later cues")
        expect(longOverlap.anchorID(at: 50, offset: 0) == longOverlap.entries[0].id, "Anchor remains active long cue")

        let model = SubtitleBrowserModel()
        let first = SubtitleBrowserSource(id: "media-a|primary", title: "Primary", offset: 0) { document }
        await model.load(first)
        expect(model.matches.count == 4 && !model.isLoading, "Successful read")
        model.query = "station"
        let appended = SubtitleBrowserSource(id: first.id, title: first.title, revision: "new", offset: 0) {
            SubtitleBrowserDocument(parts: [part(12, 14, "station"), part(30, 32, "another station")], isPartial: true)
        }
        await model.load(appended)
        expect(model.query == "station" && model.matches.count == 2, "Generated additions preserve and refresh search")
        expect(model.document.isPartial, "Incomplete results remain explicitly partial")
        expect(model.loadedKey == appended.requestKey, "Only committed source revision can seek")

        var pending: CheckedContinuation<SubtitleBrowserDocument, Never>?
        let old = Task { @MainActor in
            await model.load(SubtitleBrowserSource(id: "old-media", title: "Old", offset: 0) {
                await withCheckedContinuation { pending = $0 }
            })
        }
        while pending == nil { await Task.yield() }
        await model.load(first)
        pending?.resume(returning: earlier)
        await old.value
        expect(model.document.entries == document.entries, "Late result cannot replace new media")
        expect(model.query.isEmpty, "Changing media clears old query")

        pending = nil
        let closing = Task { @MainActor in
            await model.load(SubtitleBrowserSource(id: "closing", title: "Closing", offset: 0) {
                await withCheckedContinuation { pending = $0 }
            })
        }
        while pending == nil { await Task.yield() }
        model.invalidate()
        pending?.resume(returning: earlier)
        await closing.value
        expect(model.document.entries.isEmpty, "Closing browser rejects late read even if loader ignores cancellation")
        await model.load(SubtitleBrowserSource(id: "bitmap", title: "Bitmap", offset: 0) { throw SubtitleBrowserError.bitmap })
        expect(model.statusKey == "SB.Bitmap" && !model.canRetry, "Bitmap source has specific unsupported state")
        await model.load(SubtitleBrowserSource(id: "large-remote", title: "Remote", offset: 0) { throw SubtitleBrowserError.remoteLimit })
        expect(model.statusKey == "SB.RemoteLimit" && !model.canRetry, "Read budget offers local download instead of an endless retry")
        let indexed = SubtitleBrowserDocument(parts: [part(1, 2, "indexed")], isPartial: true, partialStatusKey: "SB.Indexed")
        expect(indexed.isPartial && indexed.partialStatusKey == "SB.Indexed", "Remote index coverage is not labelled as generated content")
        await model.load(SubtitleBrowserSource(id: "network", title: "Network", offset: 0) { throw CocoaError(.fileReadUnknown) })
        expect(model.statusKey == "SB.ReadFailed" && model.canRetry, "Transient read failure can retry")
        await model.load(first)
        expect(!model.canRetry && model.statusKey == nil, "Retry restores normal state")
        await model.load(nil)
        expect(model.matches.isEmpty && model.statusKey == "SB.SelectSubtitle", "Turning subtitles off clears content")
        print("Passed \(checks) subtitle browser checks")
    }
}
