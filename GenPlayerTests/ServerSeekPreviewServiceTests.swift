import Foundation
import Testing
@testable import GenPlayer

struct ServerSeekPreviewServiceTests {
    @Test("Trickplay parser keeps normal Jellyfin thumbnail totals unchanged")
    func trickplayParserPreservesNormalThumbnailCounts() {
        let payload: [String: Any] = [
            "Trickplay": [
                "320": [
                    "Width": 320,
                    "Height": 180,
                    "TileWidth": 10,
                    "TileHeight": 10,
                    "ThumbnailCount": 766,
                    "Interval": 10_000,
                ]
            ]
        ]

        guard let previewManifest = MediaBrowserTrickplayManifestParser.parse(
            itemPayload: payload,
            preferredMediaSourceId: nil,
            duration: 7_664.919542
        ), let manifest = previewManifest.trickplay else {
            Issue.record("Expected trickplay manifest to parse")
            return
        }

        #expect(manifest.thumbnailCount == 766)
        #expect(manifest.tileCount == 8)

        let frame = manifest.frame(at: 7_650)
        #expect(frame?.tileIndex == 7)
        #expect(frame?.row == 6)
        #expect(frame?.column == 5)
    }

    @Test("Trickplay parser expands Jellyfin tile-count payloads to real frame counts")
    func trickplayParserExpandsTileCountPayloads() {
        let payload: [String: Any] = [
            "Trickplay": [
                "320": [
                    "Width": 320,
                    "Height": 136,
                    "TileWidth": 10,
                    "TileHeight": 10,
                    "ThumbnailCount": 7,
                    "Interval": 10_000,
                ]
            ]
        ]

        guard let previewManifest = MediaBrowserTrickplayManifestParser.parse(
            itemPayload: payload,
            preferredMediaSourceId: nil,
            duration: 6_426.272
        ), let manifest = previewManifest.trickplay else {
            Issue.record("Expected trickplay manifest to parse")
            return
        }

        #expect(manifest.thumbnailCount == 642)
        #expect(manifest.tileCount == 7)

        let frame = manifest.frame(at: 6_410)
        #expect(frame?.tileIndex == 6)
        #expect(frame?.row == 4)
        #expect(frame?.column == 1)
    }
    @Test("Trickplay parser expands Jellyfin tile-count payloads using implicit Fallback Duration from RunTimeTicks")
    func trickplayParserExpandsTileCountsWithFallbackDuration() {
        let payload: [String: Any] = [
            "RunTimeTicks": 64_260_000_000 as Int64,
            "Trickplay": [
                "320": [
                    "Width": 320,
                    "Height": 136,
                    "TileWidth": 10,
                    "TileHeight": 10,
                    "ThumbnailCount": 7,
                    "Interval": 10_000,
                ]
            ]
        ]

        guard let previewManifest = MediaBrowserTrickplayManifestParser.parse(
            itemPayload: payload,
            preferredMediaSourceId: nil,
            duration: nil
        ), let manifest = previewManifest.trickplay else {
            Issue.record("Expected trickplay manifest to parse with fallback duration")
            return
        }

        #expect(manifest.thumbnailCount == 642)
        #expect(manifest.tileCount == 7)
    }

    @Test("Trickplay parser falls back to richer source-specific variant when source-less count is sparse")
    func trickplayParserPrefersRicherVariantAcrossSources() {
        let payload: [String: Any] = [
            "RunTimeTicks": 64_260_000_000 as Int64,
            "Trickplay": [
                "320": [
                    "Width": 320,
                    "Height": 136,
                    "TileWidth": 10,
                    "TileHeight": 10,
                    "ThumbnailCount": 7,
                    "Interval": 10_000,
                ],
                "media-source-a": [
                    "320": [
                        "Width": 320,
                        "Height": 180,
                        "TileWidth": 10,
                        "TileHeight": 10,
                        "ThumbnailCount": 766,
                        "Interval": 10_000,
                    ]
                ]
            ]
        ]

        guard let previewManifest = MediaBrowserTrickplayManifestParser.parse(
            itemPayload: payload,
            preferredMediaSourceId: nil,
            duration: nil
        ), let manifest = previewManifest.trickplay else {
            Issue.record("Expected trickplay manifest to parse across mixed source variants")
            return
        }

        #expect(manifest.mediaSourceId == "media-source-a")
        #expect(manifest.thumbnailCount == 766)
    }

    @Test("Trickplay parser keeps preferred media source when width ties")
    func trickplayParserKeepsPreferredSourceWhenProvided() {
        let payload: [String: Any] = [
            "Trickplay": [
                "source-a": [
                    "320": [
                        "Width": 320,
                        "Height": 180,
                        "TileWidth": 10,
                        "TileHeight": 10,
                        "ThumbnailCount": 500,
                        "Interval": 10_000,
                    ]
                ],
                "source-b": [
                    "320": [
                        "Width": 320,
                        "Height": 180,
                        "TileWidth": 10,
                        "TileHeight": 10,
                        "ThumbnailCount": 800,
                        "Interval": 10_000,
                    ]
                ]
            ]
        ]

        guard let previewManifest = MediaBrowserTrickplayManifestParser.parse(
            itemPayload: payload,
            preferredMediaSourceId: "source-a",
            duration: 8_000
        ), let manifest = previewManifest.trickplay else {
            Issue.record("Expected trickplay manifest to parse with preferred source")
            return
        }

        #expect(manifest.mediaSourceId == "source-a")
        #expect(manifest.thumbnailCount == 500)
    }

    @Test("Trickplay parser extracts Chapter images when Trickplay is missing")
    func trickplayParserExtractsChaptersWhenTrickplayIsMissing() {
        let payload: [String: Any] = [
            "Id": "475360192d59fffee4fb43fef39a53a9",
            "Name": "Superman",
            "RunTimeTicks": 77_620_000_000 as Int64,
            "Chapters": [
                [
                    "StartPositionTicks": 0 as Int64,
                    "Name": "Chapter 01",
                    "ImageTag": "tag1"
                ],
                [
                    "StartPositionTicks": 29_800_000_000 as Int64, // 49:40 = 2980s
                    "Name": "Chapter 06",
                    "ImageTag": "tag6"
                ]
            ]
        ]

        guard let previewManifest = MediaBrowserTrickplayManifestParser.parse(
            itemPayload: payload,
            preferredMediaSourceId: nil,
            duration: 7_762
        ) else {
            Issue.record("Expected chapter preview manifest to parse")
            return
        }

        #expect(previewManifest.trickplay == nil)
        #expect(previewManifest.chapters.count == 2)
        #expect(previewManifest.chapters[1].name == "Chapter 06")
        #expect(previewManifest.chapters[1].startPositionSeconds == 2980)
    }
}

