#if os(macOS)
import SwiftUI
import GenPlayerCore

struct MacSettingsRow<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            content
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }
}

struct MacPlayerInspector: View {
    let file: VideoFile
    @ObservedObject var playbackService: MacVLCPlaybackService
    var activeTab: MacPlayerSheet.RightSidebarTab
    @Binding var videoAspectRatio: String
    let onSwitchPlayback: (VideoFile) -> Void
    var onAction: ((String, String) -> Void)? = nil
    let onClose: () -> Void
    
    @AppStorage("macVideoPlaybackEngine") private var defaultPlaybackEngine = "mpv"
    @AppStorage("enableSecondarySubtitlesBeta") private var enableSecondarySubtitlesBeta: Bool = false
    @AppStorage("macMPVSecondarySubtitlePosition") private var mpvSecondaryPosition: Double = 10
    @AppStorage("secondarySubtitleSizeScale") private var secondarySubtitleSizeScale: Double = 1.0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                switch activeTab {
                case .video:
                    videoTab
                case .audio:
                    audioTab
                case .subtitle:
                    subtitleTab
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(width: 320)
    }
    
    @ViewBuilder
    private var videoTab: some View {
        VStack(spacing: 10) {
            enginePicker
            let decoders = [("hw", platformShellString("Hardware (VT)")), ("avcodec", platformShellString("Software (avcodec)"))]
            let currentDecoder = UserDefaults.standard.string(forKey: "defaultVideoDecoder") ?? "hw"
            
            MacSettingsRow(title: platformShellString("Video Decoder")) {
                Picker("", selection: Binding(
                    get: { currentDecoder },
                    set: { newDecoder in
                        playbackService.setDecoder(newDecoder)
                        let decoderName = decoders.first(where: { $0.0 == newDecoder })?.1 ?? newDecoder
                        onAction?("cpu", decoderName)
                    }
                )) {
                    ForEach(decoders, id: \.0) { id, name in
                        Text(name).tag(id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            MacSettingsRow(title: platformShellString("Aspect Ratio")) {
                let ratios = ["Default", "16:9", "4:3", "16:10", "2.35:1", "2.39:1"]
                Picker("", selection: Binding(
                    get: { videoAspectRatio.isEmpty ? "Default" : videoAspectRatio },
                    set: { 
                        videoAspectRatio = $0
                        playbackService.setAspectRatio($0 == "Default" ? "" : $0)
                        onAction?("aspectratio", platformShellString($0))
                    }
                )) {
                    ForEach(ratios, id: \.self) { ratio in
                        Text(platformShellString(ratio)).tag(ratio)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            MacSettingsRow(title: platformShellString("Speed")) {
                let speeds = playbackService.isUsingMPV ? MPVPlaybackSpeed.rates : [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
                Picker("", selection: Binding(
                    get: { playbackService.targetRate },
                    set: { rate in
                        let fRate = Float(rate)
                        playbackService.setPlaybackRate(fRate)
                        let rateKey = file.type == .audio ? "defaultAudioPlaybackSpeed" : "defaultPlaybackSpeed"
                        UserDefaults.standard.set(Double(fRate), forKey: rateKey)
                        onAction?("gauge.with.dots.needle.bottom.50percent", "\(String(format: "%g", fRate))x")
                    }
                )) {
                    ForEach(speeds, id: \.self) { speed in
                        Text(speed == 1.0 ? platformShellString("Normal") : "\(String(format: "%g", speed))x").tag(Float(speed))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            if !file.availablePlaybackQualityOptions.isEmpty {
                let currentQuality = file.preferredPlaybackQualityID ?? "auto"
                MacSettingsRow(title: platformShellString("Quality")) {
                    Picker("", selection: Binding(
                        get: { currentQuality },
                        set: { newValue in
                            var newItem = file
                            newItem.preferredPlaybackQualityID = newValue
                            if let selectedOption = file.availablePlaybackQualityOptions.first(where: { $0.id == newValue }) {
                                onAction?("slider.horizontal.3", selectedOption.title)
                            }
                            onSwitchPlayback(newItem)
                        }
                    )) {
                        ForEach(file.availablePlaybackQualityOptions, id: \.id) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var enginePicker: some View {
        MacSettingsRow(title: platformShellString("MPV.Engine")) {
            Picker("", selection: Binding(
                get: { playbackService.playbackEngineID },
                set: { playbackService.switchPlaybackEngine(to: $0) }
            )) {
                Text("VLC").tag(PlaybackEngineID.vlc)
                Text(platformShellString("MPV.Name")).tag(PlaybackEngineID.mpv)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(!playbackService.canSwitchPlaybackEngine)
        }
        .help(playbackService.playbackEngineSwitchExplanation)

        if defaultPlaybackEngine != playbackService.playbackEngineID.rawValue,
           playbackService.playbackErrorMessage == nil {
            Button {
                defaultPlaybackEngine = playbackService.playbackEngineID.rawValue
            } label: {
                Text(String(format: platformShellString("MPV.SetDefaultEngine"), playbackService.isUsingMPV ? "mpv" : "VLC"))
                    .frame(maxWidth: .infinity)
            }
        }
    }
    
    @ViewBuilder
    private var audioTab: some View {
        VStack(spacing: 10) {
            if file.type == .audio { enginePicker }
            MacSettingsRow(title: platformShellString("Audio Track")) {
                Picker("", selection: Binding(
                    get: { playbackService.currentAudioTrackID },
                    set: { trackId in
                        playbackService.setAudioTrack(trackId)
                        if let matched = playbackService.audioTracks.first(where: { $0.id == trackId }) {
                            onAction?("waveform", matched.name)
                        }
                    }
                )) {
                    ForEach(playbackService.audioTracks) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            let currentAudioDelay = UserDefaults.standard.double(forKey: "audioDelaySeconds")
            
            MacSettingsRow(title: platformShellString("Audio Delay")) {
                HStack {
                    Text(currentAudioDelay == 0 ? "0.0s" : String(format: "%+.1fs", currentAudioDelay))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 50, alignment: .trailing)
                    Stepper("", value: Binding(
                        get: { currentAudioDelay },
                        set: { 
                            playbackService.setAudioDelay($0)
                            onAction?("waveform.badge.plus", "\(platformShellString("Audio Delay")): \(String(format: "%+.1fs", $0))")
                        }
                    ), in: -10...10, step: 0.1)
                    .labelsHidden()
                }
            }
        }
    }
    
    @ViewBuilder
    private var subtitleTab: some View {
        VStack(spacing: 10) {
            if playbackService.currentFile?.type == .video {
                Button(platformShellString("AS.Title")) { playbackService.showAudioSubtitleSheet = true }
            }

            
            MacSettingsRow(title: platformShellString("Primary Subtitle")) {
                Picker("", selection: Binding(
                    get: { playbackService.currentSubtitleTrackID },
                    set: { trackId in
                        playbackService.audioSubtitles.noteManualSubtitleSelection()
                        playbackService.setSubtitleTrack(trackId)
                        if trackId == -1 {
                            onAction?("captions.bubble", platformShellString("Off"))
                        } else if let matched = playbackService.subtitleTracks.first(where: { $0.id == trackId }) {
                            onAction?("captions.bubble.fill", matched.name)
                        }
                    }
                )) {
                    if playbackService.audioSubtitles.canDisplay {
                        Text(platformShellString("AS.Generated")).tag(MacAudioSubtitlePlan.primaryID)
                    }
                    if playbackService.isUsingMPV { Text(platformShellString("Off")).tag(-1) }
                    ForEach(playbackService.subtitleTracks) { track in
                        Text(track.name).tag(track.id)
                            .disabled(!playbackService.canSelectMPVSubtitle(track.id, secondary: false))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            MacSettingsRow(title: platformShellString("Secondary Subtitles")) {
                Toggle("", isOn: $enableSecondarySubtitlesBeta)
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            if enableSecondarySubtitlesBeta && (playbackService.isUsingMPV || playbackService.currentSubtitleTrackID != -1 || playbackService.audioSubtitles.canDisplay) {
                MacSettingsRow(title: platformShellString("Secondary Subtitle")) {
                    Picker("", selection: Binding(
                        get: { playbackService.currentSecondarySubtitleTrackID },
                        set: { secTrackId in
                            playbackService.audioSubtitles.noteManualSubtitleSelection()
                            playbackService.setSecondarySubtitleTrack(secTrackId)
                            if secTrackId == MacSubtitleTranslation.trackID {
                                onAction?("character.bubble.fill", platformShellString(playbackService.audioSubtitles.translatesAudio ? "SI.TranslatedSecondary" : "Translation.Primary"))
                            } else if let secTrackId, let matched = playbackService.secondarySubtitleTracks.first(where: { $0.id == secTrackId }) {
                                onAction?("character.bubble.fill", matched.displayName)
                            } else {
                                onAction?("character.bubble", platformShellString("Off"))
                            }
                        }
                    )) {
                        Text(platformShellString("Disable")).tag(String?.none)
                        if playbackService.audioSubtitles.canDisplay {
                            Text(platformShellString("AS.Generated")).tag(Optional(MacAudioSubtitlePlan.secondaryID))
                        }
                        if #available(macOS 15.0, *), (playbackService.hasPrimarySubtitleForTranslation || playbackService.audioSubtitles.translatesAudio) {
                            Text(platformShellString(playbackService.audioSubtitles.translatesAudio ? "SI.TranslatedSecondary" : "Translation.Primary")).tag(Optional(MacSubtitleTranslation.trackID))
                        }
                        ForEach(playbackService.secondarySubtitleTracks) { track in
                            Text(track.displayName).tag(Optional(track.id))
                                .disabled(!playbackService.canSelectMPVSubtitle(track.primaryTrackID ?? -1, secondary: true))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                
                if playbackService.currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID {
                    MacSubtitleTranslationControls(model: playbackService.subtitleTranslation)
                }

                if playbackService.isUsingMPV {
                    if !playbackService.usesMPVTextSecondary && !playbackService.usesMPVNativeASSSecondary {
                    MacSettingsRow(title: platformShellString("MPV.SecondaryPosition")) {
                        Slider(value: $mpvSecondaryPosition, in: 0...100)
                            .onChange(of: mpvSecondaryPosition) { _ in playbackService.updateMPVSecondaryStyle() }
                    }
                    }
                    MacSettingsRow(title: platformShellString("MPV.SecondaryDelay")) {
                        let delay = UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
                        Text(String(format: "%+.1fs", delay)).monospacedDigit()
                        Stepper("", value: Binding(get: { delay }, set: { playbackService.setSecondarySubtitleDelay($0) }), in: -10...10, step: 0.1).labelsHidden()
                    }
                }
                MacSettingsRow(title: platformShellString("Secondary Size")) {
                    let sizes: [(Double, String)] = [(0.6, "Extra Small"), (0.8, "Small"), (1.0, "Normal"), (1.2, "Large"), (1.4, "Extra Large")]
                    Picker("", selection: Binding(
                        get: { secondarySubtitleSizeScale },
                        set: { newScale in
                            secondarySubtitleSizeScale = newScale
                            let label = sizes.first(where: { $0.0 == newScale })?.1 ?? ""
                            onAction?("textformat.size", platformShellString(label))
                        }
                    )) {
                        ForEach(sizes, id: \.0) { scale, label in
                            Text(platformShellString(label)).tag(scale)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .disabled(playbackService.isUsingMPV && !playbackService.usesMPVTextSecondary && !playbackService.usesMPVNativeASSSecondary)
            }
            
            let currentSubtitleDelay = UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
            
            MacSettingsRow(title: platformShellString("Subtitle Delay")) {
                HStack {
                    Text(currentSubtitleDelay == 0 ? "0.0s" : String(format: "%+.1fs", currentSubtitleDelay))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 50, alignment: .trailing)
                    Stepper("", value: Binding(
                        get: { currentSubtitleDelay },
                        set: { 
                            playbackService.setSubtitleDelay($0)
                            onAction?("captions.bubble", "\(platformShellString("Subtitle Delay")): \(String(format: "%+.1fs", $0))")
                        }
                    ), in: -10...10, step: 0.1)
                    .labelsHidden()
                }
            }
        }
    }
}
#endif
