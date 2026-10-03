#if os(macOS)
import SwiftUI

struct MacPlayerSubtitleBrowser: View {
    @ObservedObject var playbackService: MacVLCPlaybackService
    let onClose: () -> Void

    var body: some View {
        let session = playbackService.translationPlaybackGeneration
        let sources = playbackService.subtitleBrowserSources
        SubtitleBrowserView(sources: sources,
            currentTime: Double(playbackService.currentTime) / 1000,
            canSeek: playbackService.canSeek && playbackService.duration > 0,
            onSeek: { time in
                guard playbackService.translationPlaybackGeneration == session, playbackService.duration > 0 else { return }
                playbackService.setPosition(Float(min(1, time * 1000 / Double(playbackService.duration))))
            }, onClose: onClose, trackSelections: trackSelections(sources: sources))
            .id(session)
            .background(.regularMaterial)
            .environment(\.colorScheme, .dark)
    }

    private func trackSelections(sources: [SubtitleBrowserSource]) -> [SubtitleBrowserTrackSelection] {
        let session = playbackService.translationPlaybackGeneration.uuidString
        let primaryTitle = platformShellString("Primary")
        let secondaryTitle = platformShellString("Secondary")
        typealias Option = SubtitleBrowserTrackSelection.Option
        var primary = [Option(id: "-1", title: platformShellString("Off"))]
        if playbackService.audioSubtitles.canDisplay {
            primary.append(Option(id: String(MacAudioSubtitlePlan.primaryID), title: playbackService.generatedSubtitleName))
        }
        primary += playbackService.subtitleTracks.filter { $0.id != -1 }.map { Option(id: String($0.id), title: $0.name) }
        var result = [SubtitleBrowserTrackSelection(id: "primary", title: primaryTitle,
            selectedTrackID: String(playbackService.currentSubtitleTrackID), options: primary,
            source: sources.first { $0.id.hasPrefix(session + "|primary|") }) { id in
                guard let id = Int(id) else { return }
                if id != MacAudioSubtitlePlan.primaryID { playbackService.audioSubtitles.noteManualSubtitleSelection() }
                playbackService.setSubtitleTrack(id)
            }]
        if UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") {
            var secondary = [Option(id: "off", title: platformShellString("Off"))]
            if playbackService.audioSubtitles.canDisplay {
                secondary.append(Option(id: MacAudioSubtitlePlan.secondaryID, title: playbackService.generatedSubtitleName))
            }
            if #available(macOS 15.0, *), playbackService.hasPrimarySubtitleForTranslation || playbackService.audioSubtitles.translatesAudio {
                secondary.append(Option(id: MacSubtitleTranslation.trackID,
                    title: platformShellString(playbackService.audioSubtitles.translatesAudio ? "SI.TranslatedSecondary" : "Translation.Primary")))
            }
            secondary += playbackService.secondarySubtitleTracks.map {
                Option(id: $0.id, title: $0.displayName, isEnabled: playbackService.isUsingMPV || $0.isSelectable)
            }
            result.append(SubtitleBrowserTrackSelection(id: "secondary", title: secondaryTitle,
                selectedTrackID: playbackService.currentSecondarySubtitleTrackID ?? "off", options: secondary,
                source: sources.first { $0.id.hasPrefix(session + "|secondary|") }) { id in
                    if id != MacAudioSubtitlePlan.secondaryID { playbackService.audioSubtitles.noteManualSubtitleSelection() }
                    playbackService.setSecondarySubtitleTrack(id == "off" ? nil : id)
                })
        }
        return result
    }

}
#endif
