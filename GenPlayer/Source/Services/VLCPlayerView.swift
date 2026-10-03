import SwiftUI
import VLCKitSPM
import GenPlayerShell

struct VLCPlayerView: UIViewControllerRepresentable {
    @ObservedObject var playbackService: VLCPlaybackService
    var item: MediaItem?
    var onReady: (() -> Void)? = nil
    
    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        let controller = VLCPlayerViewController()
        controller.playbackService = playbackService
        controller.onReady = onReady
        return controller
    }
    
    func updateUIViewController(_ uiViewController: VLCPlayerViewController, context: Context) {
        uiViewController.playbackService = playbackService
        uiViewController.onReady = onReady
        uiViewController.updateVideoLayout()
    }
}

class VLCPlayerViewController: UIViewController {
    var playbackService: VLCPlaybackService?
    var onReady: (() -> Void)?
    
    private var mpvSurface: MPVVideoSurfaceView?
    private var surfaceEngine: MPVPlaybackEngine?

    private let videoContainerView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // The view where VLC renders video.
    // On Mac (macCatalyst): frame is set to exactly match the video aspect ratio (centered),
    //   so VLC renders into a correctly-sized view and adds no internal letterboxing.
    // On iOS/tvOS: fills the container; transform-based scaling handles fill/zoom.
    private let videoView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.translatesAutoresizingMaskIntoConstraints = true  // frame-based layout
        return v
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // videoContainerView fills the whole view
        view.addSubview(videoContainerView)
        NSLayoutConstraint.activate([
            videoContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            videoContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        // videoView uses frame-based layout, managed in updateVideoLayout()
        videoContainerView.addSubview(videoView)
        
        // Force layout pass so frames are valid for VLC
        view.layoutIfNeeded()
        updateVideoLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateVideoLayout()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateVideoLayout()
        if let service = playbackService {
            if service.reattachRetainedPlayerViewForPictureInPictureRestoreIfNeeded(to: videoView) {
                service.pipUsableViewController = self
                updateVideoLayout()
                onReady?()
                if #available(iOS 11.0, *) {
                    setNeedsUpdateOfHomeIndicatorAutoHidden()
                    setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
                }
                return
            }

            service.playerView = videoView
            if !service.isUsingMPV, !service.isVideoPiPActive,
               (service.mediaPlayer?.drawable as AnyObject?) !== videoView {
                service.mediaPlayer?.drawable = videoView
            }
            service.pipUsableViewController = self
            updateVideoLayout()
            onReady?()
        }

        if #available(iOS 11.0, *) {
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.main.async { [weak playbackService, weak self] in
            guard let playbackService = playbackService else { return }
            if playbackService.isVideoPiPActive { return }
            guard playbackService.state.status == .idle || (!playbackService.isUsingMPV && playbackService.mediaPlayer?.media == nil) else { return }
            playbackService.playerView = nil
            playbackService.mediaPlayer?.drawable = nil
            if playbackService.pipUsableViewController === self {
                playbackService.pipUsableViewController = nil
            }
        }
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool { return true }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }

    func updateVideoLayout() {
        if surfaceEngine !== playbackService?.mpvEngine {
            mpvSurface?.removeFromSuperview()
            mpvSurface = nil
            surfaceEngine = playbackService?.mpvEngine
            if let engine = surfaceEngine, !engine.usesPixelBufferOutput {
                let surface = engine.videoSurfaceView
                surface.frame = videoView.bounds
                surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                videoView.addSubview(surface)
                mpvSurface = surface
            }
        }
        let containerBounds = videoContainerView.bounds.integral
        guard containerBounds.width > 1, containerBounds.height > 1 else { return }

        guard let playbackService else {
            videoView.transform = .identity
            videoView.frame = containerBounds
            return
        }

#if targetEnvironment(macCatalyst)
        // Mac-specific path:
        // Size videoView to exactly match the video aspect ratio and center it in the container.
        // This eliminates VLC internal letterboxing.
        let macNaturalSize = playbackService.videoNaturalSize
        if macNaturalSize.width > 1, macNaturalSize.height > 1,
           let macAspect = VLCPlaybackService.resolvedVideoAspectRatio(
               override: playbackService.state.aspectRatio,
               naturalSize: macNaturalSize
           ), macAspect.isFinite, macAspect > 0 {
            let targetFrame = Self.centeredVideoFrame(
                in: containerBounds,
                aspect: macAspect,
                displayMode: playbackService.state.videoDisplayMode
            )
            videoView.transform = .identity
            if videoView.frame != targetFrame {
                videoView.frame = targetFrame
            }
            return
        }
        // Aspect ratio not yet available: fill container
        videoView.transform = .identity
        videoView.frame = containerBounds
#else
        // UIKit frame assignment is undefined under a nonidentity transform.
        // MPV's pixel surface must keep the untransformed viewport while zooming.
        if playbackService.isUsingMPV { videoView.transform = .identity }
        videoView.frame = containerBounds

        let fitRect = VLCPlaybackService.visibleVideoRect(
            containerSize: containerBounds.size,
            naturalVideoSize: playbackService.videoNaturalSize,
            aspectRatioOverride: playbackService.state.aspectRatio,
            displayMode: .fit
        )

        let baseScale = VLCPlaybackService.interactiveVideoBaseScale(
            containerSize: containerBounds.size,
            naturalVideoSize: playbackService.videoNaturalSize,
            aspectRatioOverride: playbackService.state.aspectRatio,
            displayMode: playbackService.state.videoDisplayMode
        )
        let userZoomScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(
            playbackService.state.interactiveVideoZoomScale
        )
        let totalScale = baseScale * userZoomScale
        let clampedOffset = VLCPlaybackService.clampedInteractiveVideoOffset(
            containerBounds: containerBounds,
            baseVideoRect: fitRect,
            totalScale: totalScale,
            proposedOffset: playbackService.state.interactiveVideoOffset
        )

        if abs(clampedOffset.width - playbackService.state.interactiveVideoOffset.width) > 0.5 ||
            abs(clampedOffset.height - playbackService.state.interactiveVideoOffset.height) > 0.5 ||
            abs(userZoomScale - playbackService.state.interactiveVideoZoomScale) > 0.001 {
            DispatchQueue.main.async { [weak playbackService] in
                playbackService?.updateInteractiveVideoTransform(
                    zoomScale: userZoomScale,
                    offset: clampedOffset
                )
            }
        }

        let scaleTransform = CGAffineTransform(scaleX: totalScale, y: totalScale)
        let translationTransform = CGAffineTransform(
            translationX: clampedOffset.width,
            y: clampedOffset.height
        )
        videoView.transform = scaleTransform.concatenating(translationTransform)
#endif
    }

    /// Mac only: compute a centered frame within container that exactly fits (or fills)
    /// the video at the given aspect ratio (width / height).
    private static func centeredVideoFrame(
        in container: CGRect,
        aspect: CGFloat,
        displayMode: VideoDisplayMode
    ) -> CGRect {
        let cw = container.width
        let ch = container.height

        let videoWidth: CGFloat
        let videoHeight: CGFloat

        if displayMode == .fill {
            if cw / aspect >= ch {
                videoWidth = cw
                videoHeight = (cw / aspect).rounded()
            } else {
                videoHeight = ch
                videoWidth = (ch * aspect).rounded()
            }
        } else {
            if cw / aspect <= ch {
                videoWidth = cw
                videoHeight = (cw / aspect).rounded()
            } else {
                videoHeight = ch
                videoWidth = (ch * aspect).rounded()
            }
        }

        let x = ((cw - videoWidth) / 2).rounded()
        let y = ((ch - videoHeight) / 2).rounded()
        return CGRect(
            x: container.minX + x,
            y: container.minY + y,
            width: videoWidth,
            height: videoHeight
        )
    }
}
