import Photos
import SwiftUI

struct SideControlsView: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @Binding var isLocked: Bool
    var leadingPadding: CGFloat? = nil
    var trailingPadding: CGFloat? = nil
    var onAction: ((String, String) -> Void)?
    var onMenuWillOpen: (() -> Void)? = nil
    var onMenuDismiss: (() -> Void)? = nil
    var onOpenAspectRatioMenu: (() -> Void)? = nil
    var onRotateCompleted: (() -> Void)? = nil
    @State private var isShowingScreenshotDestinationSheet = false
    @State private var controlSafeAreaInsets: UIEdgeInsets?

    private let settings = AppSettings.shared
    
    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let defaultSidePadding: CGFloat = isLandscape ? 40 : 32 // Increased from 20 for better portrait spacing
            let resolvedLeadingPadding = controlSafeAreaInsets.map { defaultSidePadding + $0.left }
                ?? leadingPadding ?? defaultSidePadding
            let resolvedTrailingPadding = controlSafeAreaInsets.map { defaultSidePadding + $0.right }
                ?? trailingPadding ?? defaultSidePadding
            let verticalSpacing: CGFloat = isLandscape ? 40 : 30
            
            HStack {
                // LEFT SIDE
                VStack(spacing: verticalSpacing) {
                    // Lock Button (Top)
                    Button(action: {
                        withAnimation { isLocked.toggle() }
                        onAction?(isLocked ? "lock.fill" : "lock.open", isLocked ? NSLocalizedString("Locked", comment: "") : NSLocalizedString("Unlocked", comment: ""))
                    }) {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    }
                    .buttonStyle(GlassButtonStyle())
                    
                    // Rotate Button (Bottom) - Only visible if not locked
                    if !isLocked {
                        Button(action: {
                            rotateScreen()
                        }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                }
                .padding(.leading, resolvedLeadingPadding)
                
                Spacer()
                
                // RIGHT SIDE
                if !isLocked {
                    VStack(spacing: verticalSpacing) {
                        // Screenshot Button (Top)
                        Button(action: {
                            handleScreenshotButton()
                        }) {
                            Image(systemName: "camera.viewfinder")
                        }
                        .buttonStyle(GlassButtonStyle())
                        
                        // Aspect Ratio Menu
                        AspectRatioMenuButton(
                            playbackService: playbackService,
                            onMenuWillOpen: onMenuWillOpen,
                            onAction: onAction,
                            onDismiss: onMenuDismiss,
                            legacyOnOpen: onOpenAspectRatioMenu
                        )
                        .equatable()
                        .buttonStyle(GlassButtonStyle())
                    }
                    .padding(.trailing, resolvedTrailingPadding)
                }
            }
            .onPlayerControlSafeAreaChange { controlSafeAreaInsets = $0 }
            .frame(maxHeight: .infinity, alignment: .center) // Vertical Center
        }
        .actionSheet(isPresented: $isShowingScreenshotDestinationSheet) {
            ActionSheet(
                title: Text(NSLocalizedString("Choose Screenshot Save Location", comment: "")),
                message: Text(NSLocalizedString("Choose where Gen Player saves screenshots. You can change this later in Advanced Settings.", comment: "")),
                buttons: [
                    .default(Text(NSLocalizedString("Save to Gen Player", comment: ""))) {
                        saveScreenshotAfterSelecting(location: .appFolder)
                    },
                    .default(Text(NSLocalizedString("Save to Photos", comment: ""))) {
                        saveScreenshotAfterSelecting(location: .photos)
                    },
                    .cancel()
                ]
            )
        }
    }
    
    private func rotateScreen() {
        let rotatedFeedback = NSLocalizedString("Rotated", comment: "")
        let rotateFailedFeedback = NSLocalizedString("Rotate Unavailable", comment: "")

        let currentOrientation = UIApplication.activeInterfaceOrientation()
        let targetInterfaceOrientation: UIInterfaceOrientation = currentOrientation.isLandscape ? .portrait : .landscapeRight
        let targetOrientationMask: UIInterfaceOrientationMask = targetInterfaceOrientation.isLandscape ? .landscapeRight : .portrait

        UIApplication.requestInterfaceOrientation(
            targetInterfaceOrientation,
            lock: targetOrientationMask
        ) { didRotate in
            if didRotate {
                onAction?("arrow.up.left.and.arrow.down.right", rotatedFeedback)
                onRotateCompleted?()
            } else {
                onAction?("exclamationmark.triangle", rotateFailedFeedback)
            }

            AppDelegate.orientationLock = .all
            UIApplication.refreshInterfaceChrome(delays: [0, 0.12])
        }
    }

    private func handleScreenshotButton() {
        if settings.hasConfiguredSnapshotSaveLocation {
            saveScreenshot(using: settings.snapshotSaveLocation)
        } else {
            isShowingScreenshotDestinationSheet = true
        }
    }

    private func saveScreenshotAfterSelecting(location: AppSettings.SnapshotSaveLocation) {
        settings.setSnapshotSaveLocation(location)
        saveScreenshot(using: location)
    }

    private func saveScreenshot(using location: AppSettings.SnapshotSaveLocation) {
        switch location {
        case .appFolder:
            saveScreenshotToAppFolder()
        case .photos:
            saveScreenshotToPhotos()
        }
    }

    private func saveScreenshotToAppFolder(
        image: UIImage? = nil,
        message: String = NSLocalizedString("Screenshot Saved to Gen Player", comment: "")
    ) {
        guard let image else {
            playbackService.requestCurrentFrame(persist: true) { image in
                if image != nil { onAction?("camera.viewfinder", message) }
            }
            return
        }
        if playbackService.persistSnapshotImage(image) {
            onAction?("camera.viewfinder", message)
        }
    }

    private func saveScreenshotToPhotos() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        handlePhotoLibraryAuthorization(status, requestIfNeeded: true)
    }

    private func handlePhotoLibraryAuthorization(
        _ status: PHAuthorizationStatus,
        requestIfNeeded: Bool
    ) {
        switch status {
        case .authorized, .limited:
            captureAndSaveScreenshotToPhotos()
        case .notDetermined:
            guard requestIfNeeded else {
                fallbackScreenshotToAppFolder(message: NSLocalizedString("Screenshot Saved to Gen Player", comment: ""))
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                DispatchQueue.main.async {
                    self.handlePhotoLibraryAuthorization(newStatus, requestIfNeeded: false)
                }
            }
        case .denied, .restricted:
            settings.setSnapshotSaveLocation(.appFolder)
            fallbackScreenshotToAppFolder(message: NSLocalizedString("Photo Access Denied. Screenshot Saved to Gen Player Instead.", comment: ""))
        @unknown default:
            settings.setSnapshotSaveLocation(.appFolder)
            fallbackScreenshotToAppFolder(message: NSLocalizedString("Couldn't Save to Photos. Screenshot Saved to Gen Player Instead.", comment: ""))
        }
    }

    private func captureAndSaveScreenshotToPhotos() {
        playbackService.requestCurrentFrame { image in
            guard let image else { return }
            saveScreenshotToPhotos(image)
        }
    }

    private func saveScreenshotToPhotos(_ image: UIImage) {
        let handleResult: (Bool, Error?) -> Void = { success, _ in
            DispatchQueue.main.async {
                if success {
                    self.onAction?("photo", NSLocalizedString("Screenshot Saved to Photos", comment: ""))
                } else {
                    self.fallbackScreenshotToAppFolder(
                        image: image,
                        message: NSLocalizedString("Couldn't Save to Photos. Screenshot Saved to Gen Player Instead.", comment: "")
                    )
                }
            }
        }

        if let pngData = image.pngData() {
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "public.png"
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: pngData, options: options)
            }, completionHandler: handleResult)
        } else {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: handleResult)
        }
    }

    private func fallbackScreenshotToAppFolder(
        image: UIImage? = nil,
        message: String
    ) {
        saveScreenshotToAppFolder(image: image, message: message)
    }
}
