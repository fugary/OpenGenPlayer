import SwiftUI
#if os(iOS)
import UIKit
#endif

// Bitmap subtitles use native rendering, so position controls live in the menu
// rather than an invisible text-shaped drag target over the video.
private func bitmapSecondaryPositionMenu(service: VLCPlaybackService, onSelect: @escaping () -> Void) -> UIMenu {
    let actions = AppSettings.SecondarySubtitlePlacement.allCases.map { placement in
        UIAction(title: placement.localizedName,
                 state: service.secondarySubtitlePlacement == placement ? .on : .off) { [weak service] _ in
            service?.setSecondarySubtitlePlacement(placement)
            onSelect()
        }
    }
    return UIMenu(title: NSLocalizedString("Secondary Subtitle Position", comment: ""), children: actions)
}

// Keep iOS 15 on the custom fallback path because the native player menu
// presentation has historically been unstable there, while newer systems
// keep the native iOS menu animation, blur material and presentation.
private var shouldUseLegacyPlayerMenuOverlay: Bool {
    if #available(iOS 16.0, *) {
        return false
    } else {
        return true
    }
}

enum PlayerFloatingMenuScreen: Hashable {
    case audioTracks
    case subtitleTracks
    case playbackSpeed
    case aspectRatio
    case more

    var title: String {
        switch self {
        case .audioTracks:
            return NSLocalizedString("Audio", comment: "")
        case .subtitleTracks:
            return NSLocalizedString("Subtitles", comment: "")
        case .playbackSpeed:
            return NSLocalizedString("Speed", comment: "")
        case .aspectRatio:
            return NSLocalizedString("Display", comment: "")
        case .more:
            return NSLocalizedString("More", comment: "")
        }
    }
}

private extension VideoDisplayMode {
    var localizedTitle: String {
        switch self {
        case .fit:
            return NSLocalizedString("Fit to Screen", comment: "")
        case .fill:
            return NSLocalizedString("Fill Screen", comment: "")
        }
    }
}

private enum PlayerSubtitleSlot {
    case primary
    case secondary

    var title: String {
        switch self {
        case .primary:
            return NSLocalizedString("Primary", comment: "Primary subtitle menu section")
        case .secondary:
            return NSLocalizedString("Secondary", comment: "Secondary subtitle menu section")
        }
    }

    func feedbackTitle(for trackName: String) -> String {
        String(
            format: NSLocalizedString("%@: %@", comment: "Subtitle slot and selected track name"),
            title,
            trackName
        )
    }
}

struct PlayerMenuTriggerPreferenceKey: PreferenceKey {
    static var defaultValue: [PlayerFloatingMenuScreen: CGRect] = [:]

    static func reduce(value: inout [PlayerFloatingMenuScreen: CGRect], nextValue: () -> [PlayerFloatingMenuScreen: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func playerMenuTriggerFrame(for screen: PlayerFloatingMenuScreen) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PlayerMenuTriggerPreferenceKey.self,
                    value: [screen: geometry.frame(in: .global)]
                )
            }
        )
    }
}

private struct PlayerNativeMenuSnapshot: Equatable {
    /// Include the presentation boundary so a menu that was intentionally
    /// frozen while visible is rebuilt once it has been dismissed.
    let isMenuPresented: Bool
    let audioTracks: [MediaTrack]
    let currentAudioTrackID: Int
    let subtitleTracks: [MediaTrack]
    let currentSubtitleTrackID: Int
    let secondarySubtitleTracks: [MediaTrack]
    let currentSecondarySubtitleTrackID: Int
    let shouldShowSecondarySubtitleControls: Bool
    let secondarySubtitleSizeScale: Double
    let playbackRate: Float
    let aspectRatio: String
    let videoDisplayMode: VideoDisplayMode
    let hasInteractiveZoomTransform: Bool
    let currentDecoder: AppSettings.VideoDecoder
    let isUsingMPV: Bool
    let canSwitchPlaybackEngine: Bool
    let audioDelay: Double
    let subtitleDelay: Double

    init(playbackService: VLCPlaybackService) {
        isMenuPresented = playbackService.isMenuPresented
        audioTracks = playbackService.audioTracks
        currentAudioTrackID = playbackService.currentAudioTrack
        subtitleTracks = playbackService.subtitleTracks
        currentSubtitleTrackID = playbackService.currentSubtitleTrack
        secondarySubtitleTracks = playbackService.secondarySubtitleTracks
        currentSecondarySubtitleTrackID = playbackService.currentSecondarySubtitleTrackID
        shouldShowSecondarySubtitleControls = playbackService.shouldShowSecondarySubtitleControls
        secondarySubtitleSizeScale = AppSettings.shared.secondarySubtitleSizeScale.rawValue
        playbackRate = playbackService.state.rate
        aspectRatio = playbackService.state.aspectRatio
        videoDisplayMode = playbackService.state.videoDisplayMode
        hasInteractiveZoomTransform = playbackService.hasInteractiveVideoTransform
        currentDecoder = playbackService.currentDecoder
        isUsingMPV = playbackService.isUsingMPV
        canSwitchPlaybackEngine = playbackService.canSwitchPlaybackEngine
        audioDelay = playbackService.audioDelay
        subtitleDelay = playbackService.subtitleDelay
    }

    static func == (lhs: PlayerNativeMenuSnapshot, rhs: PlayerNativeMenuSnapshot) -> Bool {
        lhs.isMenuPresented == rhs.isMenuPresented &&
        lhs.audioTracks == rhs.audioTracks &&
        lhs.currentAudioTrackID == rhs.currentAudioTrackID &&
        lhs.subtitleTracks == rhs.subtitleTracks &&
        lhs.currentSubtitleTrackID == rhs.currentSubtitleTrackID &&
        lhs.secondarySubtitleTracks == rhs.secondarySubtitleTracks &&
        lhs.currentSecondarySubtitleTrackID == rhs.currentSecondarySubtitleTrackID &&
        lhs.shouldShowSecondarySubtitleControls == rhs.shouldShowSecondarySubtitleControls &&
        lhs.secondarySubtitleSizeScale == rhs.secondarySubtitleSizeScale &&
        abs(lhs.playbackRate - rhs.playbackRate) < 0.001 &&
        lhs.aspectRatio == rhs.aspectRatio &&
        lhs.videoDisplayMode == rhs.videoDisplayMode &&
        lhs.hasInteractiveZoomTransform == rhs.hasInteractiveZoomTransform &&
        lhs.isUsingMPV == rhs.isUsingMPV &&
        lhs.canSwitchPlaybackEngine == rhs.canSwitchPlaybackEngine &&
        lhs.currentDecoder == rhs.currentDecoder &&
        abs(lhs.audioDelay - rhs.audioDelay) < 0.001 &&
        abs(lhs.subtitleDelay - rhs.subtitleDelay) < 0.001
    }
}

private struct PlayerNativeMenuTrigger<Label: View>: View, Equatable {
    let playbackService: VLCPlaybackService
    let menuSnapshot: PlayerNativeMenuSnapshot
    let screen: PlayerFloatingMenuScreen
    var onMenuWillOpen: (() -> Void)? = nil
    var onImportSubtitle: (() -> Void)? = nil
    var onInfo: (() -> Void)? = nil
    var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    var selectedPlaybackQualityID: String? = nil
    var onSelectPlaybackQuality: ((String) -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    let label: () -> Label

    static func == (lhs: PlayerNativeMenuTrigger<Label>, rhs: PlayerNativeMenuTrigger<Label>) -> Bool {
        lhs.screen == rhs.screen &&
        lhs.menuSnapshot == rhs.menuSnapshot &&
        lhs.selectedPlaybackQualityID == rhs.selectedPlaybackQualityID &&
        lhs.playbackQualityOptions == rhs.playbackQualityOptions
    }

    var body: some View {
        label()
            .overlay(
                NativePlayerMenuAnchorButton(
                    playbackService: playbackService,
                    screen: screen,
                    onMenuWillOpen: onMenuWillOpen,
                    onImportSubtitle: onImportSubtitle,
                    onInfo: onInfo,
                    onAction: onAction,
                    onDismiss: onDismiss
                )
            )
    }
}

private struct NativePlayerMenuAnchorButton: UIViewRepresentable {
    let playbackService: VLCPlaybackService
    let screen: PlayerFloatingMenuScreen
    var onMenuWillOpen: (() -> Void)?
    var onImportSubtitle: (() -> Void)?
    var onInfo: (() -> Void)?
    var onAction: ((String, String) -> Void)?
    var onDismiss: (() -> Void)?

    func makeCoordinator() -> NativePlayerMenuAnchorHost.Coordinator {
        NativePlayerMenuAnchorHost.Coordinator(screen: screen)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        button.menu = context.coordinator.makeMenu(for: screen, playbackService: playbackService)

        button.addAction(UIAction { [weak playbackService] _ in
            onMenuWillOpen?()
            playbackService?.isMenuPresented = true
        }, for: .menuActionTriggered)

        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.update(
            playbackService: playbackService,
            presentationToken: nil,
            onImportSubtitle: onImportSubtitle,
            onInfo: onInfo,
            onAction: onAction,
            onDismiss: onDismiss
        )

        if !playbackService.isMenuPresented {
            uiView.menu = context.coordinator.makeMenu(for: screen, playbackService: playbackService)
        }
    }
}

struct AudioSelectionMenuButton: View, Equatable {
    let playbackService: VLCPlaybackService
    private let menuSnapshot: PlayerNativeMenuSnapshot
    var onMenuWillOpen: (() -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var legacyOnOpen: (() -> Void)? = nil

    init(
        playbackService: VLCPlaybackService,
        onMenuWillOpen: (() -> Void)? = nil,
        onAction: ((String, String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        legacyOnOpen: (() -> Void)? = nil
    ) {
        self.playbackService = playbackService
        self.menuSnapshot = PlayerNativeMenuSnapshot(playbackService: playbackService)
        self.onMenuWillOpen = onMenuWillOpen
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.legacyOnOpen = legacyOnOpen
    }

    static func == (lhs: AudioSelectionMenuButton, rhs: AudioSelectionMenuButton) -> Bool {
        lhs.menuSnapshot.isMenuPresented == rhs.menuSnapshot.isMenuPresented &&
        lhs.menuSnapshot.audioTracks == rhs.menuSnapshot.audioTracks &&
        lhs.menuSnapshot.currentAudioTrackID == rhs.menuSnapshot.currentAudioTrackID
    }

    var body: some View {
        Group {
            if shouldUseLegacyPlayerMenuOverlay, let legacyOnOpen {
                Button(action: {
                    onMenuWillOpen?()
                    legacyOnOpen()
                }) {
                    Image(systemName: "waveform")
                        .foregroundColor(.white)
                }
                .playerMenuTriggerFrame(for: .audioTracks)
            } else {
                PlayerNativeMenuTrigger(
                    playbackService: playbackService,
                    menuSnapshot: menuSnapshot,
                    screen: .audioTracks,
                    onMenuWillOpen: onMenuWillOpen,
                    onAction: onAction,
                    onDismiss: onDismiss
                ) {
                    Image(systemName: "waveform")
                        .foregroundColor(.white)
                }
                .equatable()
            }
        }
    }
}

struct SubtitleSelectionMenuButton: View, Equatable {
    let playbackService: VLCPlaybackService
    private let menuSnapshot: PlayerNativeMenuSnapshot
    var onMenuWillOpen: (() -> Void)? = nil
    var onImportSubtitle: (() -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var legacyOnOpen: (() -> Void)? = nil

    init(
        playbackService: VLCPlaybackService,
        onMenuWillOpen: (() -> Void)? = nil,
        onImportSubtitle: (() -> Void)? = nil,
        onAction: ((String, String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        legacyOnOpen: (() -> Void)? = nil
    ) {
        self.playbackService = playbackService
        self.menuSnapshot = PlayerNativeMenuSnapshot(playbackService: playbackService)
        self.onMenuWillOpen = onMenuWillOpen
        self.onImportSubtitle = onImportSubtitle
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.legacyOnOpen = legacyOnOpen
    }

    static func == (lhs: SubtitleSelectionMenuButton, rhs: SubtitleSelectionMenuButton) -> Bool {
        lhs.menuSnapshot.isMenuPresented == rhs.menuSnapshot.isMenuPresented &&
        lhs.menuSnapshot.subtitleTracks == rhs.menuSnapshot.subtitleTracks &&
        lhs.menuSnapshot.currentSubtitleTrackID == rhs.menuSnapshot.currentSubtitleTrackID &&
        lhs.menuSnapshot.secondarySubtitleTracks == rhs.menuSnapshot.secondarySubtitleTracks &&
        lhs.menuSnapshot.currentSecondarySubtitleTrackID == rhs.menuSnapshot.currentSecondarySubtitleTrackID &&
        lhs.menuSnapshot.shouldShowSecondarySubtitleControls == rhs.menuSnapshot.shouldShowSecondarySubtitleControls
    }

    var body: some View {
        Group {
            if shouldUseLegacyPlayerMenuOverlay, let legacyOnOpen {
                Button(action: {
                    onMenuWillOpen?()
                    legacyOnOpen()
                }) {
                    Image(systemName: "captions.bubble")
                        .foregroundColor(.white)
                }
                .playerMenuTriggerFrame(for: .subtitleTracks)
            } else {
                PlayerNativeMenuTrigger(
                    playbackService: playbackService,
                    menuSnapshot: menuSnapshot,
                    screen: .subtitleTracks,
                    onMenuWillOpen: onMenuWillOpen,
                    onImportSubtitle: onImportSubtitle,
                    onAction: onAction,
                    onDismiss: onDismiss
                ) {
                    Image(systemName: "captions.bubble")
                        .foregroundColor(.white)
                }
                .equatable()
            }
        }
    }
}

struct PlaybackSpeedMenuButton: View, Equatable {
    let playbackService: VLCPlaybackService
    let currentRate: Float
    private let menuSnapshot: PlayerNativeMenuSnapshot
    var onMenuWillOpen: (() -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    private let legacyOnOpen: (() -> Void)?

    init(
        playbackService: VLCPlaybackService,
        currentRate: Float,
        onMenuWillOpen: (() -> Void)? = nil,
        onAction: ((String, String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        legacyOnOpen: (() -> Void)? = nil
    ) {
        self.playbackService = playbackService
        self.currentRate = currentRate
        self.menuSnapshot = PlayerNativeMenuSnapshot(playbackService: playbackService)
        self.onMenuWillOpen = onMenuWillOpen
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.legacyOnOpen = legacyOnOpen
    }

    init(currentRate: Float, onOpen: @escaping () -> Void) {
        self.playbackService = VLCPlaybackService.shared
        self.currentRate = currentRate
        self.menuSnapshot = PlayerNativeMenuSnapshot(playbackService: VLCPlaybackService.shared)
        self.onMenuWillOpen = nil
        self.onAction = nil
        self.onDismiss = nil
        self.legacyOnOpen = onOpen
    }

    static func == (lhs: PlaybackSpeedMenuButton, rhs: PlaybackSpeedMenuButton) -> Bool {
        lhs.menuSnapshot.isMenuPresented == rhs.menuSnapshot.isMenuPresented &&
        abs(lhs.currentRate - rhs.currentRate) < 0.001 &&
        abs(lhs.menuSnapshot.playbackRate - rhs.menuSnapshot.playbackRate) < 0.001
    }

    var body: some View {
        Group {
            if shouldUseLegacyPlayerMenuOverlay, let legacyOnOpen {
                Button(action: {
                    onMenuWillOpen?()
                    legacyOnOpen()
                }) {
                    speedLabel
                }
                .playerMenuTriggerFrame(for: .playbackSpeed)
            } else {
                PlayerNativeMenuTrigger(
                    playbackService: playbackService,
                    menuSnapshot: menuSnapshot,
                    screen: .playbackSpeed,
                    onMenuWillOpen: onMenuWillOpen,
                    onAction: onAction,
                    onDismiss: onDismiss
                ) {
                    speedLabel
                }
                .equatable()
            }
        }
    }

    private var speedLabel: some View {
        Text("\(String(format: "%g", currentRate))x")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .minimumScaleFactor(0.8)
    }
}

struct MoreMenuButton: View, Equatable {
    let playbackService: VLCPlaybackService
    private let menuSnapshot: PlayerNativeMenuSnapshot
    var onMenuWillOpen: (() -> Void)? = nil
    var onInfo: (() -> Void)? = nil
    var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    var selectedPlaybackQualityID: String? = nil
    var onSelectPlaybackQuality: ((String) -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var legacyOnOpen: (() -> Void)? = nil

    init(
        playbackService: VLCPlaybackService,
        onMenuWillOpen: (() -> Void)? = nil,
        onInfo: (() -> Void)? = nil,
        playbackQualityOptions: [RemotePlaybackQualityOption] = [],
        selectedPlaybackQualityID: String? = nil,
        onSelectPlaybackQuality: ((String) -> Void)? = nil,
        onAction: ((String, String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        legacyOnOpen: (() -> Void)? = nil
    ) {
        self.playbackService = playbackService
        self.menuSnapshot = PlayerNativeMenuSnapshot(playbackService: playbackService)
        self.onMenuWillOpen = onMenuWillOpen
        self.onInfo = onInfo
        self.playbackQualityOptions = playbackQualityOptions
        self.selectedPlaybackQualityID = selectedPlaybackQualityID
        self.onSelectPlaybackQuality = onSelectPlaybackQuality
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.legacyOnOpen = legacyOnOpen
    }

    static func == (lhs: MoreMenuButton, rhs: MoreMenuButton) -> Bool {
        lhs.menuSnapshot.isMenuPresented == rhs.menuSnapshot.isMenuPresented &&
        lhs.menuSnapshot.isUsingMPV == rhs.menuSnapshot.isUsingMPV &&
        lhs.menuSnapshot.canSwitchPlaybackEngine == rhs.menuSnapshot.canSwitchPlaybackEngine &&
        lhs.menuSnapshot.currentDecoder == rhs.menuSnapshot.currentDecoder &&
        abs(lhs.menuSnapshot.audioDelay - rhs.menuSnapshot.audioDelay) < 0.001 &&
        abs(lhs.menuSnapshot.subtitleDelay - rhs.menuSnapshot.subtitleDelay) < 0.001 &&
        lhs.playbackQualityOptions == rhs.playbackQualityOptions &&
        lhs.selectedPlaybackQualityID == rhs.selectedPlaybackQualityID
    }

    var body: some View {
        Group {
            if shouldUseLegacyPlayerMenuOverlay, let legacyOnOpen {
                Button(action: {
                    onMenuWillOpen?()
                    legacyOnOpen()
                }) {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.white)
                }
                .playerMenuTriggerFrame(for: .more)
            } else {
                PlayerNativeMenuTrigger(
                    playbackService: playbackService,
                    menuSnapshot: menuSnapshot,
                    screen: .more,
                    onMenuWillOpen: onMenuWillOpen,
                    onInfo: onInfo,
                    playbackQualityOptions: playbackQualityOptions,
                    selectedPlaybackQualityID: selectedPlaybackQualityID,
                    onSelectPlaybackQuality: onSelectPlaybackQuality,
                    onAction: onAction,
                    onDismiss: onDismiss
                ) {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.white)
                }
                .equatable()
            }
        }
    }
}

struct AspectRatioMenuButton: View, Equatable {
    let playbackService: VLCPlaybackService
    private let menuSnapshot: PlayerNativeMenuSnapshot
    var onMenuWillOpen: (() -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var legacyOnOpen: (() -> Void)? = nil

    init(
        playbackService: VLCPlaybackService,
        onMenuWillOpen: (() -> Void)? = nil,
        onAction: ((String, String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        legacyOnOpen: (() -> Void)? = nil
    ) {
        self.playbackService = playbackService
        self.menuSnapshot = PlayerNativeMenuSnapshot(playbackService: playbackService)
        self.onMenuWillOpen = onMenuWillOpen
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.legacyOnOpen = legacyOnOpen
    }

    static func == (lhs: AspectRatioMenuButton, rhs: AspectRatioMenuButton) -> Bool {
        lhs.menuSnapshot.isMenuPresented == rhs.menuSnapshot.isMenuPresented &&
        lhs.menuSnapshot.aspectRatio == rhs.menuSnapshot.aspectRatio &&
        lhs.menuSnapshot.videoDisplayMode == rhs.menuSnapshot.videoDisplayMode
    }

    var body: some View {
        Group {
            if shouldUseLegacyPlayerMenuOverlay, let legacyOnOpen {
                Button(action: {
                    onMenuWillOpen?()
                    legacyOnOpen()
                }) {
                    Image(systemName: "aspectratio")
                        .foregroundColor(.white)
                }
                .playerMenuTriggerFrame(for: .aspectRatio)
            } else {
                PlayerNativeMenuTrigger(
                    playbackService: playbackService,
                    menuSnapshot: menuSnapshot,
                    screen: .aspectRatio,
                    onMenuWillOpen: onMenuWillOpen,
                    onAction: onAction,
                    onDismiss: onDismiss
                ) {
                    Image(systemName: "aspectratio")
                        .foregroundColor(.white)
                        // The UIKit menu anchor does not inherit GlassButtonStyle.
                        .font(.system(size: 16))
                        .frame(width: 38, height: 38)
                        .background(
                            VisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                                .opacity(0.8)
                                .clipShape(Circle())
                        )
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                }
                .equatable()
            }
        }
    }
}

private struct NativePlayerMenuAnchorHost: UIViewRepresentable {
    @ObservedObject var playbackService: VLCPlaybackService
    let screen: PlayerFloatingMenuScreen
    let presentationToken: UUID?
    var onImportSubtitle: (() -> Void)?
    var onInfo: (() -> Void)?
    var onAction: ((String, String) -> Void)?
    var onDismiss: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(screen: screen)
    }

    func makeUIView(context: Context) -> PlayerMenuAnchorView {
        let view = PlayerMenuAnchorView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PlayerMenuAnchorView, context: Context) {
        context.coordinator.update(
            playbackService: playbackService,
            presentationToken: presentationToken,
            onImportSubtitle: onImportSubtitle,
            onInfo: onInfo,
            onAction: onAction,
            onDismiss: onDismiss
        )
    }

    final class Coordinator: NSObject {
        private weak var anchorView: PlayerMenuAnchorView?
        private weak var playbackService: VLCPlaybackService?
        private let screen: PlayerFloatingMenuScreen
        private var onImportSubtitle: (() -> Void)?
        private var onInfo: (() -> Void)?
        private var onAction: ((String, String) -> Void)?
        private var onDismiss: (() -> Void)?
        private var pendingDismissWorkItem: DispatchWorkItem?
        private var lastPresentedToken: UUID?

        init(screen: PlayerFloatingMenuScreen) {
            self.screen = screen
        }

        func attach(to anchorView: PlayerMenuAnchorView) {
            self.anchorView = anchorView
        }

        func update(
            playbackService: VLCPlaybackService,
            presentationToken: UUID?,
            onImportSubtitle: (() -> Void)?,
            onInfo: (() -> Void)?,
            onAction: ((String, String) -> Void)?,
            onDismiss: (() -> Void)?
        ) {
            self.playbackService = playbackService
            self.onImportSubtitle = onImportSubtitle
            self.onInfo = onInfo
            self.onAction = onAction
            self.onDismiss = onDismiss

            guard let token = presentationToken, token != lastPresentedToken else { return }
            lastPresentedToken = token

            DispatchQueue.main.async { [weak self] in
                self?.presentMenuIfNeeded()
            }
        }

        private func presentMenuIfNeeded() {
            guard let anchorView, let playbackService else { return }

            playbackService.isMenuPresented = true
            anchorView.prepareAnchor()
            anchorView.menuButton.menu = makeMenu(for: screen, playbackService: playbackService)
            presentMenu(anchorView.menuButton)
        }

        func makeMenu(for screen: PlayerFloatingMenuScreen, playbackService: VLCPlaybackService) -> UIMenu {
            let children: [UIMenuElement]

            switch screen {
            case .audioTracks:
                children = audioTrackActions(playbackService: playbackService)
            case .subtitleTracks:
                children = subtitleTrackActions(playbackService: playbackService)
            case .playbackSpeed:
                children = playbackRateActions(playbackService: playbackService)
            case .aspectRatio:
                children = displayMenuChildren(playbackService: playbackService)
            case .more:
                children = moreMenuChildren(playbackService: playbackService)
            }

            let finalChildren = children.isEmpty ? [disabledPlaceholder(title: screen.title)] : children
            return UIMenu(title: "", children: finalChildren)
        }

        private func audioTrackActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            playbackService.audioTracks.map { track in
                UIAction(
                    title: track.name,
                    state: playbackService.currentAudioTrack == track.id ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setAudioTrack(track.id)
                    self.onAction?("waveform", track.name)
                }
            }
        }

        private func subtitleTrackActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            var items: [UIMenuElement] = []
            if playbackService.canBrowseSubtitles {
                items.append(UIAction(title: NSLocalizedString("SB.Title", comment: ""), image: UIImage(systemName: "text.magnifyingglass")) { [weak self, weak playbackService] _ in
                    self?.finishPresentation()
                    DispatchQueue.main.async { playbackService?.showSubtitleBrowser = true }
                })
            }
            if #available(iOS 26.0, *) {
                items.append(UIAction(title: NSLocalizedString("AS.Title", comment: ""), image: UIImage(systemName: "waveform")) { [weak self, weak playbackService] _ in
                    self?.finishPresentation()
                    DispatchQueue.main.async { playbackService?.subtitleIntelligence.presentSettings(audio: true) }
                })
            }
            if #available(iOS 18.0, *), playbackService.currentSubtitleTrack != -1 {
                items.append(UIAction(title: NSLocalizedString("Translation.Primary", comment: ""), image: UIImage(systemName: "captions.bubble")) { [weak self, weak playbackService] _ in
                    self?.finishPresentation()
                    DispatchQueue.main.async { playbackService?.subtitleIntelligence.presentSettings(audio: false) }
                })
            }
            if playbackService.shouldShowSecondarySubtitleControls {
                items.append(
                    subtitleTrackMenu(
                        slot: .primary,
                        tracks: playbackService.subtitleTracks,
                        selectedTrackID: playbackService.currentSubtitleTrack
                    ) { [weak self, weak playbackService] track in
                        guard let self, let playbackService else { return }
                        self.finishPresentation()
                        playbackService.setSubtitleTrack(track.id)
                        self.onAction?("captions.bubble", PlayerSubtitleSlot.primary.feedbackTitle(for: track.name))
                    }
                )
            } else {
                items.append(contentsOf: subtitleTrackActionItems(
                    slot: .primary,
                    tracks: playbackService.subtitleTracks,
                    selectedTrackID: playbackService.currentSubtitleTrack
                ) { [weak self, weak playbackService] track in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setSubtitleTrack(track.id)
                    self.onAction?("captions.bubble", PlayerSubtitleSlot.primary.feedbackTitle(for: track.name))
                })
            }

            if playbackService.shouldShowSecondarySubtitleControls {
                items.append(subtitleTrackMenu(
                    slot: .secondary,
                    tracks: playbackService.secondarySubtitleTracks,
                    selectedTrackID: playbackService.currentSecondarySubtitleTrackID
                ) { [weak self, weak playbackService] track in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setSecondarySubtitleTrack(track.id)
                    self.onAction?("captions.bubble", PlayerSubtitleSlot.secondary.feedbackTitle(for: track.name))
                })

            }

            if let onImportSubtitle = onImportSubtitle {
                items.append(
                    UIAction(
                        title: NSLocalizedString("Load Subtitle File", comment: ""),
                        image: UIImage(systemName: "plus.rectangle.on.folder")
                    ) { [weak self] _ in
                        self?.finishPresentation()
                        DispatchQueue.main.async {
                            onImportSubtitle()
                        }
                    }
                )
            }

            return items
        }

        private func subtitleTrackMenu(
            slot: PlayerSubtitleSlot,
            tracks: [MediaTrack],
            selectedTrackID: Int,
            onSelect: @escaping (MediaTrack) -> Void
        ) -> UIMenu {
            var actions = subtitleTrackActionItems(
                slot: slot,
                tracks: tracks,
                selectedTrackID: selectedTrackID,
                onSelect: onSelect
            )
            if slot == .secondary, let service = playbackService, service.isNativeBitmapSecondarySubtitle {
                actions.append(bitmapSecondaryPositionMenu(service: service) { [weak self] in self?.finishPresentation() })
            }
            return UIMenu(title: slot.title, options: .displayInline, children: actions)
        }

        private func subtitleTrackActionItems(
            slot: PlayerSubtitleSlot,
            tracks: [MediaTrack],
            selectedTrackID: Int,
            onSelect: @escaping (MediaTrack) -> Void
        ) -> [UIMenuElement] {
            if tracks.isEmpty {
                return [disabledPlaceholder(title: NSLocalizedString("No Subtitle Tracks", comment: ""))]
            }

            return tracks.map { track in
                let isDisabled = slot == .secondary && !(self.playbackService?.secondarySubtitleTrackIsEnabled(track.id) ?? true)
                let action = UIAction(
                    title: track.name,
                    attributes: isDisabled ? [.disabled] : [],
                    state: selectedTrackID == track.id ? .on : .off
                ) { _ in
                    onSelect(track)
                }
                if #available(iOS 16.0, *), slot == .secondary {
                    action.subtitle = self.playbackService?.secondarySubtitleTrackDetail(track.id)
                }
                return action
            }
        }

        private func playbackRateActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            playbackService.availablePlaybackRates.map { rate in
                let title = "\(String(format: "%g", rate))x"
                return UIAction(
                    title: title,
                    state: abs(playbackService.state.rate - rate) < 0.01 ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setPlaybackRate(rate)
                    self.onAction?("speedometer", title)
                }
            }
        }

        private func displayMenuChildren(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            [
                UIMenu(
                    title: NSLocalizedString("Screen Mode", comment: ""),
                    options: .displayInline,
                    children: displayModeActions(playbackService: playbackService)
                ),
                UIMenu(
                    title: NSLocalizedString("Aspect Ratio", comment: ""),
                    options: .displayInline,
                    children: aspectRatioActions(playbackService: playbackService)
                )
            ]
        }

        private func displayModeActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            var items = VLCPlaybackService.availableVideoDisplayModes.map { mode in
                UIAction(
                    title: mode.localizedTitle,
                    state: playbackService.state.videoDisplayMode == mode ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setVideoDisplayMode(mode)
                    self.onAction?("aspectratio", mode.localizedTitle)
                }
            }
            if playbackService.hasInteractiveVideoTransform {
                items.append(
                    UIAction(
                        title: NSLocalizedString("Reset Zoom", comment: ""),
                        image: UIImage(systemName: "arrow.counterclockwise")
                    ) { [weak self, weak playbackService] _ in
                        guard let self, let playbackService else { return }
                        self.finishPresentation()
                        playbackService.resetInteractiveVideoTransform()
                        self.onAction?("arrow.counterclockwise", NSLocalizedString("Reset Zoom", comment: ""))
                    }
                )
            }
            return items
        }

        private func aspectRatioActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            VLCPlaybackService.availableAspectRatios.map { ratio in
                let localizedValue = ratio.isEmpty ? NSLocalizedString("Auto", comment: "") : ratio
                return UIAction(
                    title: localizedValue,
                    state: playbackService.state.aspectRatio == ratio ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setAspectRatio(ratio)
                    self.onAction?("aspectratio", localizedValue)
                }
            }
        }

        private func moreMenuChildren(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            var items: [UIMenuElement] = [
                UIMenu(
                    title: NSLocalizedString("MPV.Engine", comment: ""),
                    image: UIImage(systemName: "play.rectangle"),
                    children: ["vlc", "mpv"].map { engine in
                        UIAction(title: engine == "mpv" ? "mpv" : "VLC",
                            attributes: playbackService.canSwitchPlaybackEngine ? [] : .disabled,
                            state: (playbackService.isUsingMPV == (engine == "mpv")) ? .on : .off
                        ) { [weak self, weak playbackService] _ in
                            guard let self, let playbackService else { return }
                            self.finishPresentation()
                            playbackService.switchPlaybackEngine(to: engine)
                        }
                    } + [UIAction(
                        title: String(format: NSLocalizedString("MPV.SetDefaultEngine", comment: ""), playbackService.isUsingMPV ? "mpv" : "VLC"),
                        attributes: playbackService.hasTerminalPlaybackFailure ? .disabled : [],
                        state: playbackService.isCurrentPlaybackEngineDefault ? .on : .off
                    ) { [weak self, weak playbackService] _ in
                        guard let self, let playbackService else { return }
                        self.finishPresentation()
                        playbackService.saveCurrentPlaybackEngineAsDefault()
                    }]
                ),
                UIMenu(
                    title: NSLocalizedString("Video Decoder", comment: ""),
                    image: UIImage(systemName: playbackService.currentDecoder == .hardware ? "cpu" : "cpu.fill"),
                    children: decoderActions(playbackService: playbackService)
                ),
                UIMenu(
                    title: NSLocalizedString("Audio Delay", comment: ""),
                    image: UIImage(systemName: "speaker.wave.2.circle"),
                    children: audioDelayActions(playbackService: playbackService)
                ),
                UIMenu(
                    title: NSLocalizedString("Subtitle Delay", comment: ""),
                    image: UIImage(systemName: "captions.bubble"),
                    children: subtitleDelayActions(playbackService: playbackService)
                )
            ]

            if onInfo != nil {
                items.append(
                    UIAction(
                        title: NSLocalizedString("Video Info", comment: ""),
                        image: UIImage(systemName: "info.circle")
                    ) { [weak self] _ in
                        self?.finishPresentation()
                        DispatchQueue.main.async {
                            self?.onInfo?()
                        }
                    }
                )
            }

            return items
        }

        private func decoderActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            [AppSettings.VideoDecoder.hardware, AppSettings.VideoDecoder.software].map { decoder in
                let title = decoder.localizedName
                return UIAction(
                    title: title,
                    state: playbackService.currentDecoder == decoder ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setDecoder(decoder)
                    self.onAction?(decoder == .hardware ? "cpu" : "cpu.fill", decoder.localizedName)
                }
            }
        }

        private func audioDelayActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            delayActions(selectedValue: playbackService.audioDelay) { [weak self, weak playbackService] value, label in
                guard let self, let playbackService else { return }
                self.finishPresentation()
                playbackService.setAudioDelay(value)
                self.onAction?("clock.arrow.2.circlepath", label)
            }
        }

        private func subtitleDelayActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            delayActions(selectedValue: playbackService.subtitleDelay) { [weak self, weak playbackService] value, label in
                guard let self, let playbackService else { return }
                self.finishPresentation()
                playbackService.setSubtitleDelay(value)
                self.onAction?("clock.arrow.2.circlepath", label)
            }
        }

        private func delayActions(
            selectedValue: Double,
            onSelect: @escaping (Double, String) -> Void
        ) -> [UIMenuElement] {
            [-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0].map { value in
                let label = delayLabel(for: value)
                return UIAction(
                    title: label,
                    state: abs(selectedValue - value) < 0.001 ? .on : .off
                ) { _ in
                    onSelect(value, label)
                }
            }
        }

        private func disabledPlaceholder(title: String) -> UIMenuElement {
            UIAction(title: title, attributes: .disabled) { _ in }
        }

        private func delayLabel(for value: Double) -> String {
            if abs(value) < 0.001 {
                return "0s"
            }
            let sign = value > 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", value))s"
        }

        private func finishPresentation() {
            pendingDismissWorkItem?.cancel()
            pendingDismissWorkItem = nil
            DispatchQueue.main.async { [weak self] in
                self?.playbackService?.isMenuPresented = false
                self?.playbackService?.flushDeferredTrackRefreshIfNeeded()
                self?.onDismiss?()
            }
        }

        private func presentMenu(_ button: UIButton) {
            button.isEnabled = true
            button.isHidden = false
            if #available(iOS 16.0, *) {
                // Keep the anchor effectively invisible on newer systems to avoid
                // transient source-view artifacts (small dot/ripple) while the menu animates in.
                button.alpha = max(button.alpha, 0.001)
            } else {
                button.alpha = max(button.alpha, 0.01)
            }
            button.setNeedsLayout()
            button.layoutIfNeeded()

            if #available(iOS 17.4, *) {
                button.performPrimaryAction()
            } else {
                // On iOS 15/16, the tap event path is more reliable than
                // primaryActionTriggered for showing a button-backed UIMenu.
                button.sendActions(for: .touchUpInside)
            }
        }
    }
}

private final class PlayerMenuAnchorView: UIView {
    let menuButton = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        menuButton.backgroundColor = .clear
        menuButton.tintColor = .clear
        menuButton.setTitle(nil, for: .normal)
        menuButton.setImage(nil, for: .normal)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.adjustsImageWhenHighlighted = false
        menuButton.alpha = 0.001
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        menuButton.frame = bounds.integral
    }

    func prepareAnchor() {
        setNeedsLayout()
        layoutIfNeeded()
        menuButton.layoutIfNeeded()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}

// Only old systems need the full-screen floating overlay host. Newer systems
// present the menu directly from each button's own native anchor.
struct PlayerFloatingMenuOverlay: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @Binding var activeScreen: PlayerFloatingMenuScreen?
    var triggerFrames: [PlayerFloatingMenuScreen: CGRect]
    var onImportSubtitle: (() -> Void)? = nil
    var onInfo: (() -> Void)? = nil
    var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    var selectedPlaybackQualityID: String? = nil
    var onSelectPlaybackQuality: ((String) -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            if shouldUseLegacyPlayerMenuOverlay {
                LegacyCustomPlayerMenuOverlay(
                    playbackService: playbackService,
                    activeScreen: $activeScreen,
                    triggerFrames: triggerFrames,
                    onImportSubtitle: onImportSubtitle,
                    onInfo: onInfo,
                    playbackQualityOptions: playbackQualityOptions,
                    selectedPlaybackQualityID: selectedPlaybackQualityID,
                    onSelectPlaybackQuality: onSelectPlaybackQuality,
                    onAction: onAction,
                    onDismiss: onDismiss
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Color.clear
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(shouldUseLegacyPlayerMenuOverlay && activeScreen != nil)
        .ignoresSafeArea()
    }
}

private enum LegacyPlayerMenuSubscreen: Hashable {
    case playbackEngine
    case decoder
    case audioDelay
    case subtitleDelay
    case playbackQuality
    case secondarySubtitle

    var title: String {
        switch self {
        case .playbackEngine:
            return NSLocalizedString("MPV.Engine", comment: "")
        case .decoder:
            return NSLocalizedString("Video Decoder", comment: "")
        case .audioDelay:
            return NSLocalizedString("Audio Delay", comment: "")
        case .subtitleDelay:
            return NSLocalizedString("Subtitle Delay", comment: "")
        case .playbackQuality:
            return NSLocalizedString("Playback Quality", comment: "")
        case .secondarySubtitle:
            return NSLocalizedString("Secondary", comment: "Secondary subtitle menu section")
        }
    }
}

private enum LegacyPlayerMenuTransitionDirection {
    case forward
    case backward
}

private struct LegacyPlayerMenuPlacement {
    let width: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat
    let opensAboveTrigger: Bool

    var transitionAnchor: UnitPoint {
        opensAboveTrigger ? .bottom : .top
    }
}

private struct LegacyCustomPlayerMenuOverlay: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @ObservedObject private var settings = AppSettings.shared
    @Binding var activeScreen: PlayerFloatingMenuScreen?
    var triggerFrames: [PlayerFloatingMenuScreen: CGRect]
    var onImportSubtitle: (() -> Void)? = nil
    var onInfo: (() -> Void)? = nil
    var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    var selectedPlaybackQualityID: String? = nil
    var onSelectPlaybackQuality: ((String) -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var activeSubscreen: LegacyPlayerMenuSubscreen? = nil
    @State private var transitionDirection: LegacyPlayerMenuTransitionDirection = .forward

    var body: some View {
        GeometryReader { geometry in
            let placement = menuPlacement(in: geometry.size)

            ZStack {
                if activeScreen != nil {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            closeMenu()
                        }

                    menuCard(in: geometry.size, placement: placement)
                        .transition(menuCardTransition(for: placement))
                }
            }
        }
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.92, blendDuration: 0.08), value: activeScreen != nil)
        .animation(.interactiveSpring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.08), value: activeSubscreen)
        .onChange(of: activeScreen) { newValue in
            transitionDirection = .forward
            if newValue != .more {
                activeSubscreen = nil
            }
            if newValue == nil {
                activeSubscreen = nil
            }
        }
    }

    private func menuCard(in containerSize: CGSize, placement: LegacyPlayerMenuPlacement) -> some View {
        return VStack(spacing: 0) {
            if activeSubscreen != nil {
                headerView

                Divider()
                    .background(Color.white.opacity(0.08))
            }

            rowsContainer(in: containerSize, reverseRootRowOrder: placement.opensAboveTrigger)
        }
        .frame(width: placement.width)
        .background(
            ZStack {
                VisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.06),
                        Color.white.opacity(0.02),
                        Color.black.opacity(0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Color.black.opacity(0.08)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.34), radius: 16, x: 0, y: 8)
        .position(x: placement.centerX, y: placement.centerY)
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            Button(action: { navigateBackToRoot() }) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }

            Text(activeSubscreen?.title ?? activeScreen?.title ?? "")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: 30, height: 30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.white.opacity(0.015)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private func rowsContainer(in containerSize: CGSize, reverseRootRowOrder: Bool) -> some View {
        let maxBodyHeight = maximumMenuBodyHeight(in: containerSize)
        let requiresScrolling = estimatedMenuBodyHeight > maxBodyHeight + 0.5

        Group {
            if requiresScrolling {
                ScrollView(showsIndicators: false) {
                    animatedRowsView(reverseRootRowOrder: reverseRootRowOrder)
                }
                .frame(height: maxBodyHeight)
            } else {
                animatedRowsView(reverseRootRowOrder: reverseRootRowOrder)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func animatedRowsView(reverseRootRowOrder: Bool) -> some View {
        ZStack {
            if activeSubscreen == nil {
                rootRowsView(reverseRootRowOrder: reverseRootRowOrder)
                    .transition(rootRowsTransition)
            }

            if let activeSubscreen {
                submenuRowsView(activeSubscreen, reverseRowOrder: reverseRootRowOrder)
                    .transition(submenuRowsTransition)
            }
        }
    }

    @ViewBuilder
    private func rootRowsView(reverseRootRowOrder: Bool) -> some View {
        VStack(spacing: 0) {
            if let activeScreen {
                switch activeScreen {
                case .audioTracks:
                    let tracks = ordered(playbackService.audioTracks, reverseIfNeeded: reverseRootRowOrder)
                    if tracks.isEmpty {
                        disabledRow(title: activeScreen.title)
                    } else {
                        ForEach(tracks, id: \.id) { track in
                            optionRow(
                                title: track.name,
                                isSelected: playbackService.currentAudioTrack == track.id
                            ) {
                                playbackService.setAudioTrack(track.id)
                                onAction?("waveform", track.name)
                                closeMenu()
                            }
                        }
                    }
                case .subtitleTracks:
                    subtitleRowsView(reverseRowOrder: reverseRootRowOrder)
                case .playbackSpeed:
                    ForEach(ordered(playbackService.availablePlaybackRates, reverseIfNeeded: reverseRootRowOrder), id: \.self) { rate in
                        let title = "\(String(format: "%g", rate))x"
                        optionRow(
                            title: title,
                            isSelected: abs(playbackService.state.rate - rate) < 0.01
                        ) {
                            playbackService.setPlaybackRate(rate)
                            onAction?("speedometer", title)
                            closeMenu()
                        }
                    }
                case .aspectRatio:
                    if reverseRootRowOrder {
                        aspectRatioRows(reverseIfNeeded: true)
                        sectionDivider
                        displayModeRows(reverseIfNeeded: true)
                    } else {
                        displayModeRows(reverseIfNeeded: false)
                        sectionDivider
                        aspectRatioRows(reverseIfNeeded: false)
                    }
                case .more:
                    moreRowsView(reverseRowOrder: reverseRootRowOrder)
                }
            }
        }
    }

    @ViewBuilder
    private func subtitleRowsView(reverseRowOrder: Bool) -> some View {
        if playbackService.canBrowseSubtitles {
            optionRow(title: NSLocalizedString("SB.Title", comment: ""), icon: "text.magnifyingglass") {
                closeMenu()
                DispatchQueue.main.async { playbackService.showSubtitleBrowser = true }
            }
        }
        if #available(iOS 26.0, *) {
            optionRow(title: NSLocalizedString("AS.Title", comment: ""), icon: "waveform") {
                closeMenu()
                DispatchQueue.main.async { playbackService.subtitleIntelligence.presentSettings(audio: true) }
            }
        }
        if #available(iOS 18.0, *), playbackService.currentSubtitleTrack != -1 {
            optionRow(title: NSLocalizedString("Translation.Primary", comment: ""), icon: "captions.bubble") {
                closeMenu()
                DispatchQueue.main.async { playbackService.subtitleIntelligence.presentSettings(audio: false) }
            }
        }

        if reverseRowOrder {
            importSubtitleRow()
            if playbackService.shouldShowSecondarySubtitleControls {
                subtitleTrackSection(
                    slot: .secondary,
                    tracks: playbackService.secondarySubtitleTracks,
                    selectedTrackID: playbackService.currentSecondarySubtitleTrackID,
                    reverseIfNeeded: true
                ) { track in
                    playbackService.setSecondarySubtitleTrack(track.id)
                }
            }
            subtitleTrackSection(
                slot: .primary,
                tracks: playbackService.subtitleTracks,
                selectedTrackID: playbackService.currentSubtitleTrack,
                reverseIfNeeded: true,
                showsHeader: playbackService.shouldShowSecondarySubtitleControls
            ) { track in
                playbackService.setSubtitleTrack(track.id)
            }
        } else {
            subtitleTrackSection(
                slot: .primary,
                tracks: playbackService.subtitleTracks,
                selectedTrackID: playbackService.currentSubtitleTrack,
                reverseIfNeeded: false,
                showsHeader: playbackService.shouldShowSecondarySubtitleControls
            ) { track in
                playbackService.setSubtitleTrack(track.id)
            }
            if playbackService.shouldShowSecondarySubtitleControls {
                sectionDivider
                subtitleTrackSection(
                    slot: .secondary,
                    tracks: playbackService.secondarySubtitleTracks,
                    selectedTrackID: playbackService.currentSecondarySubtitleTrackID,
                    reverseIfNeeded: false
                ) { track in
                    playbackService.setSecondarySubtitleTrack(track.id)
                }
            }
            importSubtitleRow()
        }
    }

    @ViewBuilder
    private func subtitleTrackSection(
        slot: PlayerSubtitleSlot,
        tracks: [MediaTrack],
        selectedTrackID: Int,
        reverseIfNeeded: Bool,
        showsHeader: Bool = true,
        onSelect: @escaping (MediaTrack) -> Void
    ) -> some View {
        let orderedTracks = ordered(tracks, reverseIfNeeded: reverseIfNeeded)
        if showsHeader {
            sectionHeader(title: slot.title)
        }

        if orderedTracks.isEmpty {
            disabledRow(title: NSLocalizedString("No Subtitle Tracks", comment: ""))
        } else {
            ForEach(orderedTracks, id: \.id) { track in
                let isDisabled = slot == .secondary && !playbackService.secondarySubtitleTrackIsEnabled(track.id)
                optionRow(
                    title: track.name,
                    subtitle: slot == .secondary ? playbackService.secondarySubtitleTrackDetail(track.id) : nil,
                    isSelected: selectedTrackID == track.id,
                    isEnabled: !isDisabled
                ) {
                    onSelect(track)
                    onAction?("captions.bubble", slot.feedbackTitle(for: track.name))
                    closeMenu()
                }
            }
        }
        if slot == .secondary, playbackService.isNativeBitmapSecondarySubtitle {
            sectionHeader(title: NSLocalizedString("Secondary Subtitle Position", comment: ""))
            ForEach(AppSettings.SecondarySubtitlePlacement.allCases) { placement in
                optionRow(title: placement.localizedName,
                          isSelected: playbackService.secondarySubtitlePlacement == placement) {
                    playbackService.setSecondarySubtitlePlacement(placement)
                    closeMenu()
                }
            }
        }
    }

    @ViewBuilder
    private func secondarySubtitleSettings() -> some View {
        HStack(spacing: 12) {
            Text(NSLocalizedString("Enable", comment: ""))
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.94))
            Spacer(minLength: 12)
            Toggle("", isOn: $settings.enableSecondarySubtitlesBeta)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            settings.enableSecondarySubtitlesBeta.toggle()
        }

        if settings.enableSecondarySubtitlesBeta, !playbackService.isNativeBitmapSecondarySubtitle {
            HStack(spacing: 12) {
                Text(NSLocalizedString("Size", comment: ""))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.white.opacity(0.94))
                Spacer(minLength: 12)
                HStack(spacing: 16) {
                    Button {
                        let allCases = AppSettings.SecondarySubtitleSizeScale.allCases
                        if let index = allCases.firstIndex(of: settings.secondarySubtitleSizeScale), index > 0 {
                            settings.secondarySubtitleSizeScale = allCases[index - 1]
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    Text(String(format: "%.1fx", settings.secondarySubtitleSizeScale.rawValue))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 40)
                        
                    Button {
                        let allCases = AppSettings.SecondarySubtitleSizeScale.allCases
                        if let index = allCases.firstIndex(of: settings.secondarySubtitleSizeScale), index < allCases.count - 1 {
                            settings.secondarySubtitleSizeScale = allCases[index + 1]
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func importSubtitleRow() -> some View {
        if onImportSubtitle != nil {
            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.horizontal, 16)

            optionRow(
                title: NSLocalizedString("Load Subtitle File", comment: ""),
                icon: "plus.rectangle.on.folder"
            ) {
                closeMenu()
                DispatchQueue.main.async {
                    onImportSubtitle?()
                }
            }
        }
    }

    @ViewBuilder
    private func submenuRowsView(_ subscreen: LegacyPlayerMenuSubscreen, reverseRowOrder: Bool) -> some View {
        VStack(spacing: 0) {
            switch subscreen {
            case .playbackEngine:
                ForEach(ordered(["vlc", "mpv"], reverseIfNeeded: reverseRowOrder), id: \.self) { engine in
                    optionRow(title: engine == "mpv" ? "mpv" : "VLC",
                              isSelected: playbackService.isUsingMPV == (engine == "mpv")) {
                        closeMenu()
                        playbackService.switchPlaybackEngine(to: engine)
                    }
                    .disabled(!playbackService.canSwitchPlaybackEngine)
                }
                optionRow(
                    title: String(format: NSLocalizedString("MPV.SetDefaultEngine", comment: ""), playbackService.isUsingMPV ? "mpv" : "VLC"),
                    isSelected: playbackService.isCurrentPlaybackEngineDefault
                ) {
                    playbackService.saveCurrentPlaybackEngineAsDefault()
                    closeMenu()
                }
                .disabled(playbackService.hasTerminalPlaybackFailure)
            case .decoder:
                let decoders = ordered(Array(AppSettings.VideoDecoder.allCases), reverseIfNeeded: reverseRowOrder)
                ForEach(decoders) { decoder in
                    optionRow(
                        title: decoder.localizedName,
                        isSelected: playbackService.currentDecoder == decoder
                    ) {
                        playbackService.setDecoder(decoder)
                        onAction?(decoder == .hardware ? "cpu" : "cpu.fill",
                                  decoder.localizedName)
                        closeMenu()
                    }
                }
            case .audioDelay:
                delayRows(selectedValue: playbackService.audioDelay, reverseIfNeeded: reverseRowOrder) { value, label in
                    playbackService.setAudioDelay(value)
                    onAction?("clock.arrow.2.circlepath", label)
                    closeMenu()
                }
            case .subtitleDelay:
                delayRows(selectedValue: playbackService.subtitleDelay, reverseIfNeeded: reverseRowOrder) { value, label in
                    playbackService.setSubtitleDelay(value)
                    onAction?("clock.arrow.2.circlepath", label)
                    closeMenu()
                }
            case .playbackQuality:
                let options = ordered(playbackQualityOptions, reverseIfNeeded: reverseRowOrder)
                ForEach(options) { option in
                    optionRow(
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: selectedPlaybackQualityID == option.id
                    ) {
                        onSelectPlaybackQuality?(option.id)
                        onAction?(RemotePlaybackQualityCatalog.menuIconSystemName, option.title)
                        closeMenu()
                    }
                }
            case .secondarySubtitle:
                secondarySubtitleSettings()
            }
        }
    }

    @ViewBuilder
    private func moreRowsView(reverseRowOrder: Bool) -> some View {
        if reverseRowOrder {
            videoInfoMoreRow()
            secondarySubtitleMoreRow()
            subtitleDelayMoreRow()
            audioDelayMoreRow()
            decoderMoreRow()
            playbackEngineMoreRow()
            playbackQualityMoreRow()
        } else {
            playbackQualityMoreRow()
            playbackEngineMoreRow()
            decoderMoreRow()
            audioDelayMoreRow()
            subtitleDelayMoreRow()
            secondarySubtitleMoreRow()
            videoInfoMoreRow()
        }
    }
    
    @ViewBuilder
    private func secondarySubtitleMoreRow() -> some View {
        optionRow(
            title: NSLocalizedString("Secondary", comment: "Secondary subtitle menu section"),
            icon: "text.quote"
        ) {
            onAction?("text.quote", NSLocalizedString("Secondary", comment: "Secondary subtitle menu section"))
            withAnimation(.spring()) {
                activeSubscreen = .secondarySubtitle
            }
        }
    }

    @ViewBuilder
    private func playbackQualityMoreRow() -> some View {
        if playbackQualityOptions.count > 1 {
            optionRow(
                title: NSLocalizedString("Playback Quality", comment: ""),
                icon: RemotePlaybackQualityCatalog.menuIconSystemName,
                accessoryText: RemotePlaybackQualityCatalog.currentOptionTitle(from: selectedPlaybackQualityID),
                showsDisclosure: true
            ) {
                showSubscreen(.playbackQuality)
            }
        }
    }

    private func playbackEngineMoreRow() -> some View {
        optionRow(title: NSLocalizedString("MPV.Engine", comment: ""), icon: "play.rectangle",
                  accessoryText: playbackService.isUsingMPV ? "mpv" : "VLC", showsDisclosure: true) {
            showSubscreen(.playbackEngine)
        }
        .disabled(!playbackService.canSwitchPlaybackEngine)
    }

    private func decoderMoreRow() -> some View {
        optionRow(
            title: NSLocalizedString("Video Decoder", comment: ""),
            icon: playbackService.currentDecoder == .hardware ? "cpu" : "cpu.fill",
            accessoryText: playbackService.currentDecoder.localizedName,
            showsDisclosure: true
        ) {
            showSubscreen(.decoder)
        }
    }

    private func audioDelayMoreRow() -> some View {
        optionRow(
            title: NSLocalizedString("Audio Delay", comment: ""),
            icon: "speaker.wave.2.circle",
            accessoryText: legacyDelayLabel(for: playbackService.audioDelay),
            showsDisclosure: true
        ) {
            showSubscreen(.audioDelay)
        }
    }

    private func subtitleDelayMoreRow() -> some View {
        optionRow(
            title: NSLocalizedString("Subtitle Delay", comment: ""),
            icon: "captions.bubble",
            accessoryText: legacyDelayLabel(for: playbackService.subtitleDelay),
            showsDisclosure: true
        ) {
            showSubscreen(.subtitleDelay)
        }
    }

    @ViewBuilder
    private func videoInfoMoreRow() -> some View {
        if onInfo != nil {
            optionRow(
                title: NSLocalizedString("Video Info", comment: ""),
                icon: "info.circle"
            ) {
                closeMenu()
                DispatchQueue.main.async {
                    onInfo?()
                }
            }
        }
    }

    private func optionRow(
        title: String,
        icon: String? = nil,
        subtitle: String? = nil,
        accessoryText: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        showsDisclosure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isEnabled ? (isSelected ? .white : .white.opacity(0.82)) : .white.opacity(0.32))
                        .frame(width: 18)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.white.opacity(isEnabled ? (isSelected ? 1.0 : 0.94) : 0.38))
                        .multilineTextAlignment(.leading)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.white.opacity(isEnabled ? 0.6 : 0.32))
                    }
                }

                Spacer(minLength: 12)

                if let accessoryText, !accessoryText.isEmpty {
                    Text(accessoryText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(isEnabled ? 0.6 : 0.32))
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.8)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(UIColor.systemGreen))
                } else if showsDisclosure {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.42))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.11) : Color.clear)
            )
            .overlay(
                Group {
                    if isSelected && icon == nil {
                        HStack {
                            Capsule(style: .continuous)
                                .fill(Color(UIColor.systemGreen))
                                .frame(width: 3, height: 18)
                                .padding(.leading, 8)
                            Spacer()
                        }
                    }
                }
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(Color.clear)
        .disabled(!isEnabled)
    }

    private func disabledRow(title: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sectionDivider: some View {
        Divider()
            .background(Color.white.opacity(0.08))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    private func sectionHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.54))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func displayModeRows(reverseIfNeeded: Bool) -> some View {
        sectionHeader(title: NSLocalizedString("Screen Mode", comment: ""))
        ForEach(ordered(VLCPlaybackService.availableVideoDisplayModes, reverseIfNeeded: reverseIfNeeded), id: \.rawValue) { mode in
            optionRow(
                title: mode.localizedTitle,
                isSelected: playbackService.state.videoDisplayMode == mode
            ) {
                playbackService.setVideoDisplayMode(mode)
                onAction?("aspectratio", mode.localizedTitle)
                closeMenu()
            }
        }
        if playbackService.hasInteractiveVideoTransform {
            optionRow(
                title: NSLocalizedString("Reset Zoom", comment: ""),
                icon: "arrow.counterclockwise"
            ) {
                playbackService.resetInteractiveVideoTransform()
                onAction?("arrow.counterclockwise", NSLocalizedString("Reset Zoom", comment: ""))
                closeMenu()
            }
        }
    }

    @ViewBuilder
    private func aspectRatioRows(reverseIfNeeded: Bool) -> some View {
        sectionHeader(title: NSLocalizedString("Aspect Ratio", comment: ""))
        ForEach(ordered(VLCPlaybackService.availableAspectRatios, reverseIfNeeded: reverseIfNeeded), id: \.self) { ratio in
            let localizedValue = ratio.isEmpty ? NSLocalizedString("Auto", comment: "") : ratio
            optionRow(
                title: localizedValue,
                isSelected: playbackService.state.aspectRatio == ratio
            ) {
                playbackService.setAspectRatio(ratio)
                onAction?("aspectratio", localizedValue)
                closeMenu()
            }
        }
    }

    private func delayRows(
        selectedValue: Double,
        reverseIfNeeded: Bool = false,
        onSelect: @escaping (Double, String) -> Void
    ) -> some View {
        let values = ordered([-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0], reverseIfNeeded: reverseIfNeeded)
        return ForEach(values, id: \.self) { value in
            let label = legacyDelayLabel(for: value)
            optionRow(
                title: label,
                isSelected: abs(selectedValue - value) < 0.001
            ) {
                onSelect(value, label)
            }
        }
    }

    private func closeMenu() {
        activeSubscreen = nil
        activeScreen = nil
        onDismiss?()
    }

    private func showSubscreen(_ subscreen: LegacyPlayerMenuSubscreen) {
        transitionDirection = .forward
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.08)) {
            activeSubscreen = subscreen
        }
    }

    private func navigateBackToRoot() {
        transitionDirection = .backward
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.9, blendDuration: 0.08)) {
            activeSubscreen = nil
        }
    }

    private func legacyDelayLabel(for value: Double) -> String {
        if abs(value) < 0.001 {
            return "0s"
        }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", value))s"
    }

    private var rootRowsTransition: AnyTransition {
        switch transitionDirection {
        case .forward:
            return .move(edge: .leading).combined(with: .opacity)
        case .backward:
            return .move(edge: .trailing).combined(with: .opacity)
        }
    }

    private var submenuRowsTransition: AnyTransition {
        switch transitionDirection {
        case .forward:
            return .move(edge: .trailing).combined(with: .opacity)
        case .backward:
            return .move(edge: .leading).combined(with: .opacity)
        }
    }

    private func menuCardTransition(for placement: LegacyPlayerMenuPlacement) -> AnyTransition {
        let verticalOffset = AnyTransition.offset(y: placement.opensAboveTrigger ? 10 : -10)
        let scale = AnyTransition.scale(scale: 0.96, anchor: placement.transitionAnchor)
        return .asymmetric(
            insertion: verticalOffset.combined(with: scale).combined(with: .opacity),
            removal: verticalOffset.combined(with: scale).combined(with: .opacity)
        )
    }

    private func menuPlacement(in containerSize: CGSize) -> LegacyPlayerMenuPlacement {
        let width = min(300, max(236, containerSize.width - 28))
        let height = estimatedMenuHeight(in: containerSize)
        let margin: CGFloat = 14
        let safeInsets = UIApplication.currentSafeAreaInsets()
        let leftInset = safeInsets.left + margin
        let rightInset = safeInsets.right + margin
        let topInset = safeInsets.top + margin
        let bottomInset = safeInsets.bottom + margin

        guard let activeScreen,
              let triggerFrame = triggerFrames[activeScreen],
              triggerFrame != .zero else {
            return LegacyPlayerMenuPlacement(
                width: width,
                centerX: containerSize.width / 2,
                centerY: containerSize.height / 2,
                opensAboveTrigger: false
            )
        }

        let minCenterX = leftInset + width / 2
        let maxCenterX = containerSize.width - rightInset - width / 2
        let centerX = min(max(triggerFrame.midX, minCenterX), maxCenterX)

        let minCenterY = topInset + height / 2
        let maxCenterY = containerSize.height - bottomInset - height / 2
        let spaceAbove = triggerFrame.minY - topInset
        let spaceBelow = containerSize.height - bottomInset - triggerFrame.maxY
        let prefersAboveTrigger = activeScreen == .aspectRatio

        let proposedCenterY: CGFloat
        let opensAboveTrigger: Bool
        if spaceAbove >= height || spaceBelow >= height {
            // Keep the aspect-ratio side menu rising upward first, while bottom-bar
            // menus continue to prefer expanding downward only when that is natural.
            if prefersAboveTrigger && spaceAbove >= height {
                proposedCenterY = triggerFrame.minY - 12 - height / 2
                opensAboveTrigger = true
            } else if spaceBelow >= height {
                proposedCenterY = triggerFrame.maxY + 12 + height / 2
                opensAboveTrigger = false
            } else {
                proposedCenterY = triggerFrame.minY - 12 - height / 2
                opensAboveTrigger = true
            }
        } else {
            // Neither side can fully fit. Bias toward the preferred opening direction
            // and let clamping keep the menu inside the safe area.
            opensAboveTrigger = prefersAboveTrigger ? true : (spaceAbove > spaceBelow)
            if opensAboveTrigger {
                proposedCenterY = triggerFrame.minY - 12 - height / 2
            } else {
                proposedCenterY = triggerFrame.maxY + 12 + height / 2
            }
        }
        let centerY = min(max(proposedCenterY, minCenterY), maxCenterY)

        return LegacyPlayerMenuPlacement(
            width: width,
            centerX: centerX,
            centerY: centerY,
            opensAboveTrigger: opensAboveTrigger
        )
    }

    private var estimatedMenuBodyHeight: CGFloat {
        let baseRowHeight: CGFloat = 51
        let subtitleRowHeight: CGFloat = 57
        let importSectionHeight: CGFloat = onImportSubtitle == nil ? 0 : 16
        let rowCount: CGFloat

        if let activeSubscreen {
            switch activeSubscreen {
            case .playbackEngine:
                rowCount = 3
            case .decoder:
                rowCount = CGFloat(AppSettings.VideoDecoder.allCases.count)
            case .audioDelay, .subtitleDelay:
                rowCount = 9
            case .playbackQuality:
                rowCount = CGFloat(playbackQualityOptions.count)
            case .secondarySubtitle:
                rowCount = settings.enableSecondarySubtitlesBeta ? 3 : 2
            }
            return rowCount * baseRowHeight
        }

        switch activeScreen {
        case .audioTracks:
            rowCount = CGFloat(max(playbackService.audioTracks.count, 1))
            return rowCount * baseRowHeight
        case .subtitleTracks:
            let secondaryRowCount = playbackService.shouldShowSecondarySubtitleControls
                ? max(playbackService.secondarySubtitleTracks.count, 1)
                : 0
            rowCount = CGFloat(max(playbackService.subtitleTracks.count, 1) + secondaryRowCount +
                (playbackService.isNativeBitmapSecondarySubtitle ? 4 : 0))
            let importRowHeight = onImportSubtitle == nil ? 0 : baseRowHeight
            let sectionPadding: CGFloat = playbackService.shouldShowSecondarySubtitleControls ? 110 : 58
            return rowCount * baseRowHeight + importRowHeight + importSectionHeight + sectionPadding
        case .playbackSpeed:
            rowCount = CGFloat(playbackService.availablePlaybackRates.count)
            return rowCount * baseRowHeight
        case .aspectRatio:
            rowCount = CGFloat(
                VLCPlaybackService.availableVideoDisplayModes.count +
                VLCPlaybackService.availableAspectRatios.count
            )
            return rowCount * baseRowHeight + 72
        case .more:
            rowCount = CGFloat((playbackQualityOptions.count > 1 ? 1 : 0) + (onInfo == nil ? 4 : 5))
            return rowCount * subtitleRowHeight
        case nil:
            return 4 * baseRowHeight
        }
    }

    private func maximumMenuBodyHeight(in containerSize: CGSize) -> CGFloat {
        let safeInsets = UIApplication.currentSafeAreaInsets()
        let reservedVerticalSpace: CGFloat = activeSubscreen == nil ? 28 : 82
        let availableHeight = containerSize.height - safeInsets.top - safeInsets.bottom - reservedVerticalSpace
        return max(120, min(320, availableHeight))
    }

    private func estimatedMenuHeight(in containerSize: CGSize) -> CGFloat {
        let headerHeight: CGFloat = activeSubscreen == nil ? 0 : 54
        let bodyHeight = min(estimatedMenuBodyHeight, maximumMenuBodyHeight(in: containerSize))
        return headerHeight + bodyHeight
    }

    private func ordered<T>(_ values: [T], reverseIfNeeded: Bool) -> [T] {
        reverseIfNeeded ? Array(values.reversed()) : values
    }
}

private struct LegacyNativePlayerMenuHost: UIViewRepresentable {
    @ObservedObject var playbackService: VLCPlaybackService
    @Binding var activeScreen: PlayerFloatingMenuScreen?
    var triggerFrames: [PlayerFloatingMenuScreen: CGRect]
    var onImportSubtitle: (() -> Void)?
    var onInfo: (() -> Void)?
    var onAction: ((String, String) -> Void)?
    var onDismiss: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> LegacyPlayerMenuPortalView {
        let view = LegacyPlayerMenuPortalView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: LegacyPlayerMenuPortalView, context: Context) {
        context.coordinator.update(
            playbackService: playbackService,
            activeScreen: activeScreen,
            activeScreenBinding: $activeScreen,
            triggerFrames: triggerFrames,
            onImportSubtitle: onImportSubtitle,
            onInfo: onInfo,
            onAction: onAction,
            onDismiss: onDismiss
        )
    }

    final class Coordinator: NSObject {
        private weak var portalView: LegacyPlayerMenuPortalView?
        private weak var playbackService: VLCPlaybackService?
        private var activeScreenBinding: Binding<PlayerFloatingMenuScreen?>?
        private var onImportSubtitle: (() -> Void)?
        private var onInfo: (() -> Void)?
        private var onAction: ((String, String) -> Void)?
        private var onDismiss: (() -> Void)?
        private var pendingDismissWorkItem: DispatchWorkItem?
        private var lastPresentedSignature: String?

        func attach(to portalView: LegacyPlayerMenuPortalView) {
            self.portalView = portalView
        }

        func update(
            playbackService: VLCPlaybackService,
            activeScreen: PlayerFloatingMenuScreen?,
            activeScreenBinding: Binding<PlayerFloatingMenuScreen?>,
            triggerFrames: [PlayerFloatingMenuScreen: CGRect],
            onImportSubtitle: (() -> Void)?,
            onInfo: (() -> Void)?,
            onAction: ((String, String) -> Void)?,
            onDismiss: (() -> Void)?
        ) {
            self.playbackService = playbackService
            self.activeScreenBinding = activeScreenBinding
            self.onImportSubtitle = onImportSubtitle
            self.onInfo = onInfo
            self.onAction = onAction
            self.onDismiss = onDismiss

            guard let portalView else { return }

            if let screen = activeScreen {
                let frame = resolvedFrame(for: screen, from: triggerFrames, in: portalView)
                let signature = "\(screen.hashValue)-\(Int(frame.minX))-\(Int(frame.minY))-\(Int(frame.width))-\(Int(frame.height))"
                guard signature != lastPresentedSignature else { return }

                lastPresentedSignature = signature
                playbackService.isMenuPresented = true
                portalView.configureAnchor(frame: frame)
                portalView.menuButton.menu = makeMenu(for: screen, playbackService: playbackService)

                DispatchQueue.main.async { [weak self] in
                    guard let self, let portalView = self.portalView else { return }
                    self.activeScreenBinding?.wrappedValue = nil
                    self.presentMenu(portalView.menuButton)
                }
            } else {
                lastPresentedSignature = nil
            }
        }

        private func resolvedFrame(
            for screen: PlayerFloatingMenuScreen,
            from triggerFrames: [PlayerFloatingMenuScreen: CGRect],
            in portalView: LegacyPlayerMenuPortalView
        ) -> CGRect {
            if let frame = triggerFrames[screen], frame != .zero {
                return portalView.anchorFrame(fromGlobalFrame: frame)
            }

            let fallbackOrigin = CGPoint(
                x: max(24, portalView.bounds.midX - 22),
                y: max(24, portalView.bounds.midY - 22)
            )
            return CGRect(origin: fallbackOrigin, size: CGSize(width: 44, height: 44))
        }

        private func makeMenu(for screen: PlayerFloatingMenuScreen, playbackService: VLCPlaybackService) -> UIMenu {
            let children: [UIMenuElement]

            switch screen {
            case .audioTracks:
                children = audioTrackActions(playbackService: playbackService)
            case .subtitleTracks:
                children = subtitleTrackActions(playbackService: playbackService)
            case .playbackSpeed:
                children = playbackRateActions(playbackService: playbackService)
            case .aspectRatio:
                children = displayMenuChildren(playbackService: playbackService)
            case .more:
                children = moreMenuChildren(playbackService: playbackService)
            }

            let finalChildren = children.isEmpty ? [disabledPlaceholder(title: screen.title)] : children
            return UIMenu(title: "", children: finalChildren)
        }

        private func audioTrackActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            playbackService.audioTracks.map { track in
                UIAction(
                    title: track.name,
                    state: playbackService.currentAudioTrack == track.id ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setAudioTrack(track.id)
                    self.onAction?("waveform", track.name)
                }
            }
        }

        private func subtitleTrackActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            var items: [UIMenuElement] = []
            if #available(iOS 26.0, *) {
                items.append(UIAction(title: NSLocalizedString("AS.Title", comment: ""), image: UIImage(systemName: "waveform")) { [weak self, weak playbackService] _ in
                    self?.finishPresentation()
                    DispatchQueue.main.async { playbackService?.subtitleIntelligence.presentSettings(audio: true) }
                })
            }
            if #available(iOS 18.0, *), playbackService.currentSubtitleTrack != -1 {
                items.append(UIAction(title: NSLocalizedString("Translation.Primary", comment: ""), image: UIImage(systemName: "captions.bubble")) { [weak self, weak playbackService] _ in
                    self?.finishPresentation()
                    DispatchQueue.main.async { playbackService?.subtitleIntelligence.presentSettings(audio: false) }
                })
            }
            if playbackService.shouldShowSecondarySubtitleControls {
                items.append(
                    subtitleTrackMenu(
                        slot: .primary,
                        tracks: playbackService.subtitleTracks,
                        selectedTrackID: playbackService.currentSubtitleTrack
                    ) { [weak self, weak playbackService] track in
                        guard let self, let playbackService else { return }
                        self.finishPresentation()
                        playbackService.setSubtitleTrack(track.id)
                        self.onAction?("captions.bubble", PlayerSubtitleSlot.primary.feedbackTitle(for: track.name))
                    }
                )
            } else {
                items.append(contentsOf: subtitleTrackActionItems(
                    slot: .primary,
                    tracks: playbackService.subtitleTracks,
                    selectedTrackID: playbackService.currentSubtitleTrack
                ) { [weak self, weak playbackService] track in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setSubtitleTrack(track.id)
                    self.onAction?("captions.bubble", PlayerSubtitleSlot.primary.feedbackTitle(for: track.name))
                })
            }

            if playbackService.shouldShowSecondarySubtitleControls {
                items.append(subtitleTrackMenu(
                    slot: .secondary,
                    tracks: playbackService.secondarySubtitleTracks,
                    selectedTrackID: playbackService.currentSecondarySubtitleTrackID
                ) { [weak self, weak playbackService] track in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setSecondarySubtitleTrack(track.id)
                    self.onAction?("captions.bubble", PlayerSubtitleSlot.secondary.feedbackTitle(for: track.name))
                })

            }

            if let onImportSubtitle = onImportSubtitle {
                items.append(
                    UIAction(
                        title: NSLocalizedString("Load Subtitle File", comment: ""),
                        image: UIImage(systemName: "plus.rectangle.on.folder")
                    ) { [weak self] _ in
                        self?.finishPresentation()
                        DispatchQueue.main.async {
                            onImportSubtitle()
                        }
                    }
                )
            }

            return items
        }

        private func subtitleTrackMenu(
            slot: PlayerSubtitleSlot,
            tracks: [MediaTrack],
            selectedTrackID: Int,
            onSelect: @escaping (MediaTrack) -> Void
        ) -> UIMenu {
            var actions = subtitleTrackActionItems(
                slot: slot,
                tracks: tracks,
                selectedTrackID: selectedTrackID,
                onSelect: onSelect
            )
            if slot == .secondary, let service = playbackService, service.isNativeBitmapSecondarySubtitle {
                actions.append(bitmapSecondaryPositionMenu(service: service) { [weak self] in self?.finishPresentation() })
            }
            return UIMenu(title: slot.title, options: .displayInline, children: actions)
        }

        private func subtitleTrackActionItems(
            slot: PlayerSubtitleSlot,
            tracks: [MediaTrack],
            selectedTrackID: Int,
            onSelect: @escaping (MediaTrack) -> Void
        ) -> [UIMenuElement] {
            if tracks.isEmpty {
                return [disabledPlaceholder(title: NSLocalizedString("No Subtitle Tracks", comment: ""))]
            }

            return tracks.map { track in
                let isDisabled = slot == .secondary && !(self.playbackService?.secondarySubtitleTrackIsEnabled(track.id) ?? true)
                let action = UIAction(
                    title: track.name,
                    attributes: isDisabled ? [.disabled] : [],
                    state: selectedTrackID == track.id ? .on : .off
                ) { _ in
                    onSelect(track)
                }
                if #available(iOS 16.0, *), slot == .secondary {
                    action.subtitle = self.playbackService?.secondarySubtitleTrackDetail(track.id)
                }
                return action
            }
        }

        private func playbackRateActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            playbackService.availablePlaybackRates.map { rate in
                let title = "\(String(format: "%g", rate))x"
                return UIAction(
                    title: title,
                    state: abs(playbackService.state.rate - rate) < 0.01 ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setPlaybackRate(rate)
                    self.onAction?("speedometer", title)
                }
            }
        }

        private func displayMenuChildren(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            [
                UIMenu(
                    title: NSLocalizedString("Screen Mode", comment: ""),
                    options: .displayInline,
                    children: displayModeActions(playbackService: playbackService)
                ),
                UIMenu(
                    title: NSLocalizedString("Aspect Ratio", comment: ""),
                    options: .displayInline,
                    children: aspectRatioActions(playbackService: playbackService)
                )
            ]
        }

        private func displayModeActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            VLCPlaybackService.availableVideoDisplayModes.map { mode in
                UIAction(
                    title: mode.localizedTitle,
                    state: playbackService.state.videoDisplayMode == mode ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setVideoDisplayMode(mode)
                    self.onAction?("aspectratio", mode.localizedTitle)
                }
            }
        }

        private func aspectRatioActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            VLCPlaybackService.availableAspectRatios.map { ratio in
                let localizedValue = ratio.isEmpty ? NSLocalizedString("Auto", comment: "") : ratio
                return UIAction(
                    title: localizedValue,
                    state: playbackService.state.aspectRatio == ratio ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setAspectRatio(ratio)
                    self.onAction?("aspectratio", localizedValue)
                }
            }
        }

        private func moreMenuChildren(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            var items: [UIMenuElement] = [
                UIMenu(
                    title: NSLocalizedString("MPV.Engine", comment: ""),
                    image: UIImage(systemName: "play.rectangle"),
                    children: ["vlc", "mpv"].map { engine in
                        UIAction(title: engine == "mpv" ? "mpv" : "VLC",
                            attributes: playbackService.canSwitchPlaybackEngine ? [] : .disabled,
                            state: (playbackService.isUsingMPV == (engine == "mpv")) ? .on : .off
                        ) { [weak self, weak playbackService] _ in
                            guard let self, let playbackService else { return }
                            self.finishPresentation()
                            playbackService.switchPlaybackEngine(to: engine)
                        }
                    } + [UIAction(
                        title: String(format: NSLocalizedString("MPV.SetDefaultEngine", comment: ""), playbackService.isUsingMPV ? "mpv" : "VLC"),
                        attributes: playbackService.hasTerminalPlaybackFailure ? .disabled : [],
                        state: playbackService.isCurrentPlaybackEngineDefault ? .on : .off
                    ) { [weak self, weak playbackService] _ in
                        guard let self, let playbackService else { return }
                        self.finishPresentation()
                        playbackService.saveCurrentPlaybackEngineAsDefault()
                    }]
                ),
                UIMenu(
                    title: NSLocalizedString("Video Decoder", comment: ""),
                    image: UIImage(systemName: playbackService.currentDecoder == .hardware ? "cpu" : "cpu.fill"),
                    children: decoderActions(playbackService: playbackService)
                ),
                UIMenu(
                    title: NSLocalizedString("Audio Delay", comment: ""),
                    image: UIImage(systemName: "speaker.wave.2.circle"),
                    children: audioDelayActions(playbackService: playbackService)
                ),
                UIMenu(
                    title: NSLocalizedString("Subtitle Delay", comment: ""),
                    image: UIImage(systemName: "captions.bubble"),
                    children: subtitleDelayActions(playbackService: playbackService)
                )
            ]

            if onInfo != nil {
                items.append(
                    UIAction(
                        title: NSLocalizedString("Video Info", comment: ""),
                        image: UIImage(systemName: "info.circle")
                    ) { [weak self] _ in
                        self?.finishPresentation()
                        DispatchQueue.main.async {
                            self?.onInfo?()
                        }
                    }
                )
            }

            return items
        }

        private func decoderActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            [AppSettings.VideoDecoder.hardware, AppSettings.VideoDecoder.software].map { decoder in
                let title = decoder.localizedName
                return UIAction(
                    title: title,
                    state: playbackService.currentDecoder == decoder ? .on : .off
                ) { [weak self, weak playbackService] _ in
                    guard let self, let playbackService else { return }
                    self.finishPresentation()
                    playbackService.setDecoder(decoder)
                    self.onAction?(decoder == .hardware ? "cpu" : "cpu.fill", decoder.localizedName)
                }
            }
        }

        private func audioDelayActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            delayActions(selectedValue: playbackService.audioDelay) { [weak self, weak playbackService] value, label in
                guard let self, let playbackService else { return }
                self.finishPresentation()
                playbackService.setAudioDelay(value)
                self.onAction?("clock.arrow.2.circlepath", label)
            }
        }

        private func subtitleDelayActions(playbackService: VLCPlaybackService) -> [UIMenuElement] {
            delayActions(selectedValue: playbackService.subtitleDelay) { [weak self, weak playbackService] value, label in
                guard let self, let playbackService else { return }
                self.finishPresentation()
                playbackService.setSubtitleDelay(value)
                self.onAction?("clock.arrow.2.circlepath", label)
            }
        }

        private func delayActions(
            selectedValue: Double,
            onSelect: @escaping (Double, String) -> Void
        ) -> [UIMenuElement] {
            [-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0].map { value in
                let label = delayLabel(for: value)
                return UIAction(
                    title: label,
                    state: abs(selectedValue - value) < 0.001 ? .on : .off
                ) { _ in
                    onSelect(value, label)
                }
            }
        }

        private func disabledPlaceholder(title: String) -> UIMenuElement {
            UIAction(title: title, attributes: .disabled) { _ in }
        }

        private func delayLabel(for value: Double) -> String {
            if abs(value) < 0.001 {
                return "0s"
            }
            let sign = value > 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", value))s"
        }

        private func finishPresentation() {
            pendingDismissWorkItem?.cancel()
            pendingDismissWorkItem = nil
            DispatchQueue.main.async { [weak self] in
                self?.playbackService?.isMenuPresented = false
                self?.playbackService?.flushDeferredTrackRefreshIfNeeded()
                self?.onDismiss?()
            }
        }

        private func presentMenu(_ button: UIButton) {
            button.isEnabled = true
            button.isHidden = false
            if #available(iOS 16.0, *) {
                button.alpha = max(button.alpha, 0.001)
            } else {
                button.alpha = max(button.alpha, 0.01)
            }
            button.setNeedsLayout()
            button.layoutIfNeeded()
            button.sendActions(for: .touchUpInside)
        }
    }
}

private final class LegacyPlayerMenuPortalView: UIView {
    let menuButton = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        menuButton.backgroundColor = .clear
        menuButton.tintColor = .clear
        menuButton.setTitle(nil, for: .normal)
        menuButton.setImage(nil, for: .normal)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.adjustsImageWhenHighlighted = false
        menuButton.alpha = 0.001
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureAnchor(frame: CGRect) {
        let anchorSize = CGSize(width: max(1, frame.width), height: max(1, frame.height))
        let maxX = max(0, bounds.width - anchorSize.width)
        let maxY = max(0, bounds.height - anchorSize.height)
        let origin = CGPoint(
            x: min(max(frame.origin.x, 0), maxX),
            y: min(max(frame.origin.y, 0), maxY)
        )
        menuButton.frame = CGRect(origin: origin, size: anchorSize).integral
    }

    func anchorFrame(fromGlobalFrame frame: CGRect) -> CGRect {
        guard let window else {
            return frame
        }

        let frameInWindow = window.convert(frame, from: nil)
        return convert(frameInWindow, from: window)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}
