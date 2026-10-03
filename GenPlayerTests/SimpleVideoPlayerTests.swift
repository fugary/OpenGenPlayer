//
//  SimpleVideoPlayerTests.swift
//  SimpleVideoPlayerTests
//
//  Created by Gary Fu on 2026/1/18.
//

import Foundation
import CoreGraphics
import Testing
@testable import GenPlayer

struct SimpleVideoPlayerTests {
    @Test("Playback delay setters clamp to supported range")
    func delayClamping() {
        let service = VLCPlaybackService.shared
        let settings = AppSettings.shared
        let originalAudioDelay = settings.audioDelaySeconds
        let originalSubtitleDelay = settings.subtitleDelaySeconds
        let originalItem = service.state.currentItem
        
        defer {
            settings.audioDelaySeconds = originalAudioDelay
            settings.subtitleDelaySeconds = originalSubtitleDelay
            service.state.currentItem = originalItem
        }
        
        service.state.currentItem = nil
        
        service.setAudioDelay(99)
        #expect(abs(settings.audioDelaySeconds - 10.0) < 0.0001)
        
        service.setAudioDelay(-99)
        #expect(abs(settings.audioDelaySeconds + 10.0) < 0.0001)
        
        service.setSubtitleDelay(99)
        #expect(abs(settings.subtitleDelaySeconds - 10.0) < 0.0001)
        
        service.setSubtitleDelay(-99)
        #expect(abs(settings.subtitleDelaySeconds + 10.0) < 0.0001)
    }
    
    @Test("External subtitle track ID helpers round-trip correctly")
    func externalSubtitleTrackHelpers() {
        let service = VLCPlaybackService.shared
        let originalCandidates = service.externalSubtitleCandidates
        
        defer {
            service.externalSubtitleCandidates = originalCandidates
        }
        
        let first = URL(fileURLWithPath: "/tmp/video.zh.srt")
        let second = URL(fileURLWithPath: "/tmp/video.en.srt")
        service.externalSubtitleCandidates = [first, second]
        
        let id = service.externalSubtitleTrackID(for: second)
        #expect(id == service.externalSubtitleTrackBaseID + 1)
        
        if let id {
            #expect(service.isExternalSubtitleTrack(id))
            #expect(service.externalSubtitleURL(forTrackID: id) == second)
        } else {
            Issue.record("Expected external subtitle track ID for second subtitle")
        }
        
        #expect(!service.isExternalSubtitleTrack(service.externalSubtitleTrackBaseID - 1))
    }
    
    @Test("Snapshot media name and filename are sanitized predictably")
    func snapshotNameSanitization() {
        let sanitized = VLCPlaybackService.sanitizedSnapshotMediaName(from: "  My:Video?/Name  ")
        #expect(sanitized == "My_Video_Name")
        
        let fallback = VLCPlaybackService.sanitizedSnapshotMediaName(from: "   ")
        #expect(fallback == "video")
        
        let longName = String(repeating: "a", count: 100)
        #expect(VLCPlaybackService.sanitizedSnapshotMediaName(from: longName).count == 64)
        
        let fileName = VLCPlaybackService.snapshotFileName(mediaName: "Movie Name", date: Date(timeIntervalSince1970: 1))
        #expect(fileName.hasPrefix("snapshot_Movie_Name_"))
        #expect(fileName.hasSuffix(".jpg"))
        #expect(fileName.range(of: #"\d{8}_\d{6}_\d{3}"#, options: .regularExpression) != nil)
    }

    @Test("Video display helpers keep fit and fill geometry distinct")
    func videoDisplayGeometry() {
        let container = CGSize(width: 100, height: 100)
        let naturalSize = CGSize(width: 1920, height: 1080)

        let parsedAspectRatio = VLCPlaybackService.parsedAspectRatioValue(from: "4:3")
        #expect(parsedAspectRatio != nil)
        #expect(abs((parsedAspectRatio ?? 0) - (4.0 / 3.0)) < 0.0001)

        let fitRect = VLCPlaybackService.visibleVideoRect(
            containerSize: container,
            naturalVideoSize: naturalSize,
            aspectRatioOverride: "",
            displayMode: .fit
        )
        #expect(abs(fitRect.width - 100) < 0.001)
        #expect(abs(fitRect.height - 56.25) < 0.001)
        #expect(abs(fitRect.minY - 21.875) < 0.001)

        let fillVisibleRect = VLCPlaybackService.visibleVideoRect(
            containerSize: container,
            naturalVideoSize: naturalSize,
            aspectRatioOverride: "",
            displayMode: .fill
        )
        #expect(fillVisibleRect == CGRect(origin: .zero, size: container))

        let fillDrawableRect = VLCPlaybackService.drawableVideoFrame(
            containerSize: container,
            naturalVideoSize: naturalSize,
            aspectRatioOverride: "",
            displayMode: .fill
        )
        #expect(abs(fillDrawableRect.width - 177.77778) < 0.01)
        #expect(abs(fillDrawableRect.height - 100) < 0.001)
        #expect(abs(fillDrawableRect.minX + 38.88889) < 0.01)

        let forcedAspectFitRect = VLCPlaybackService.visibleVideoRect(
            containerSize: CGSize(width: 160, height: 90),
            naturalVideoSize: .zero,
            aspectRatioOverride: "4:3",
            displayMode: .fit
        )
        #expect(abs(forcedAspectFitRect.width - 120) < 0.001)
        #expect(abs(forcedAspectFitRect.height - 90) < 0.001)
        #expect(abs(forcedAspectFitRect.minX - 20) < 0.001)
    }

    @Test("Interactive video transform clamps zoom and pan without exposing black bars")
    func interactiveVideoTransformGeometry() {
        let containerBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let portraitVideo = CGSize(width: 1080, height: 1920)
        let fitRect = VLCPlaybackService.visibleVideoRect(
            containerSize: containerBounds.size,
            naturalVideoSize: portraitVideo,
            aspectRatioOverride: "",
            displayMode: .fit
        )

        let fillBaseScale = VLCPlaybackService.interactiveVideoBaseScale(
            containerSize: containerBounds.size,
            naturalVideoSize: portraitVideo,
            aspectRatioOverride: "",
            displayMode: .fill
        )
        #expect(abs(fillBaseScale - 1.77778) < 0.01)

        let clampedFillOffset = VLCPlaybackService.clampedInteractiveVideoOffset(
            containerBounds: containerBounds,
            baseVideoRect: fitRect,
            totalScale: fillBaseScale,
            proposedOffset: CGSize(width: 0, height: 100)
        )
        #expect(abs(clampedFillOffset.height - 38.88889) < 0.02)
        #expect(abs(clampedFillOffset.width) < 0.001)

        let fitZoomScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(99)
        #expect(abs(fitZoomScale - 3.0) < 0.001)

        let transformedFitRect = VLCPlaybackService.transformedVideoRect(
            baseVideoRect: fitRect,
            containerBounds: containerBounds,
            totalScale: 2.0,
            offset: .zero
        )
        #expect(abs(transformedFitRect.width - 112.5) < 0.02)
        #expect(abs(transformedFitRect.minX + 6.25) < 0.02)

        let clampedFitOffset = VLCPlaybackService.clampedInteractiveVideoOffset(
            containerBounds: containerBounds,
            baseVideoRect: fitRect,
            totalScale: 2.0,
            proposedOffset: CGSize(width: 60, height: 0)
        )
        #expect(abs(clampedFitOffset.width - 6.25) < 0.02)
        #expect(abs(clampedFitOffset.height) < 0.001)
    }

    @Test("Subtitle text sanitization strips ASS tags, HTML tags, and decodes HTML entities")
    func subtitleTextSanitization() {
        let assSample = "{\\an8}那其实是我的灯 我姑妈送的"
        #expect(SubtitleModel.cleanSubtitleText(assSample) == "那其实是我的灯 我姑妈送的")

        let complexAssSample = "{\\pos(192,240)\\fs20\\c&H00FFFF&}Hello World\\NSecond Line"
        #expect(SubtitleModel.cleanSubtitleText(complexAssSample) == "Hello World\nSecond Line")

        let htmlSample = "<font color=\"#ff0000\"><b><i>{\\an8}Important text</i></b></font>"
        #expect(SubtitleModel.cleanSubtitleText(htmlSample) == "Important text")

        let entitiesSample = "&quot;You&apos;re right!&quot; &amp; that&#39;s it.&nbsp;"
        #expect(SubtitleModel.cleanSubtitleText(entitiesSample) == "\"You're right!\" & that's it.")

        let srtContent = """
        1
        00:00:01,000 --> 00:00:05,000
        {\\an8}那其实是我的灯 我姑妈送的

        2
        00:00:06,000 --> 00:00:10,000
        <i>That's actually my lamp.</i>
        """
        let parts = SubtitleModel.parseParts(from: srtContent, format: "srt")
        #expect(parts.count == 2)
        #expect(parts[0].text?.string == "那其实是我的灯 我姑妈送的")
        #expect(parts[1].text?.string == "That's actually my lamp.")
    }
}

