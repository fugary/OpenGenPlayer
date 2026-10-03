import SwiftUI
import GenPlayerShell
#if os(iOS)
import UIKit
#endif

struct ImagePreviewView: View {
    let initialFile: VideoFile
    var isIsolated: Bool = false // If true, do not scan directory for other images
    
    // Remote Context
    var contextFiles: [VideoFile]? = nil
    var playlist: [VideoFile]? = nil
    var networkService: AppNetworkService? = nil
    var server: ServerConfig? = nil
    
    @Environment(\.presentationMode) var presentationMode
    
    @State private var allImages: [VideoFile] = []
    @State private var currentIndex: Int = 0
    @State private var isLoaded: Bool = false
    @State private var showControls: Bool = true // Toggle for immersive mode
    @State private var headerTitle: String = ""
    
    @State private var readyImage: UIImage?
    @State private var readyImageURL: URL?
    private struct TextSelectionImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }
    @State private var textSelectionImage: TextSelectionImage?

    private var currentImage: UIImage? {
        guard allImages.indices.contains(currentIndex),
              readyImageURL == allImages[currentIndex].url else { return nil }
        return readyImage
    }

    var body: some View {
        ZStack {
            // Background — extends behind status bar / nav bar
            // Background — adapts to light/dark mode
            Color(UIColor.systemBackground).ignoresSafeArea()
            
            // Image Pager
            if !allImages.isEmpty {
                TabView(selection: $currentIndex) {
                    ForEach(0..<allImages.count, id: \.self) { index in
                        AsyncImageLoaderView(
                            file: allImages[index],
                            initialFile: initialFile,
                            networkService: networkService,
                            server: server,
                            isCurrent: index == currentIndex,
                            onImageReady: { image in
                                guard allImages.indices.contains(currentIndex),
                                      allImages[currentIndex].url == allImages[index].url else { return }
                                readyImageURL = allImages[index].url
                                readyImage = image
                            },
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls.toggle()
                                }
                            }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .onChange(of: currentIndex) { newIndex in
                    if allImages.indices.contains(newIndex) {
                        headerTitle = allImages[newIndex].name
                    }
                }
            } else {
                Text(NSLocalizedString("Loading...", comment: ""))
                    .foregroundColor(.secondary)
            }
            
            // Bottom page indicator
            if showControls && !allImages.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                         Spacer()
                         Text("\(currentIndex + 1) / \(allImages.count)")
                             .foregroundColor(.primary)
                             .font(.footnote)
                             .padding(.vertical, 8)
                             .padding(.horizontal, 16)
                             .background(Color(UIColor.secondarySystemBackground).opacity(0.8))
                             .cornerRadius(16)
                         Spacer()
                    }
                    .padding(.bottom, 20)
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: !showControls)
        // Standard navbar — same as TextPreviewView
        .navigationBarTitle(headerTitle, displayMode: .inline)
        .navigationBarHidden(!showControls)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if LiveTextCapability.isSupported {
                    Button {
                        guard let image = currentImage else { return }
                        // The shared analyzer expects upright pixels; photos may carry EXIF rotation.
                        let uprightImage: UIImage
                        if image.imageOrientation == .up {
                            uprightImage = image
                        } else {
                            let format = UIGraphicsImageRendererFormat()
                            format.scale = image.scale
                            uprightImage = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                                image.draw(in: CGRect(origin: .zero, size: image.size))
                            }
                        }
                        textSelectionImage = TextSelectionImage(image: uprightImage)
                    } label: {
                        AppToolbarIcon(systemName: "text.viewfinder")
                    }
                    .accessibilityLabel(NSLocalizedString("Live Text", comment: ""))
                    .disabled(currentImage == nil)
                }
            }
        }
        .fullScreenCover(item: $textSelectionImage) { selection in
            PlayerLiveTextViewer(image: selection.image, onDismiss: { textSelectionImage = nil })
        }
        .onAppear {
            if !isLoaded {
                setupImages()
            }
        }
    }
    
    private func setupImages() {
        if let playlist = playlist, !playlist.isEmpty {
            // Use provided playlist (already sorted/filtered by caller)
            allImages = playlist
            currentIndex = allImages.firstIndex(where: { $0.url == initialFile.url }) ?? 0
        } else if let context = contextFiles {
            // Remote Mode
            let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "bmp", "tiff"]
            let images = context
                .filter { $0.type == .image || imageExtensions.contains($0.url.pathExtension.lowercased()) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            
            allImages = images
            // Match by name because initialFile.url is local, but context file.url is remote
            currentIndex = allImages.firstIndex(where: { $0.name == initialFile.name }) ?? 0
        } else if isIsolated {
            // Isolated Mode
            allImages = [initialFile]
            currentIndex = 0
        } else {
            // Local Directory Mode
            loadImagesFromDirectory()
        }
        
        if allImages.indices.contains(currentIndex) {
            headerTitle = allImages[currentIndex].name
        } else {
            headerTitle = initialFile.name
        }
        
        isLoaded = true
    }
    
    private func loadImagesFromDirectory() {
        let directoryURL = initialFile.url.deletingLastPathComponent()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            allImages = [initialFile]
            return
        }
        
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "bmp", "tiff"]
        let images = contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                VideoFile(name: url.lastPathComponent, url: url, type: .image, size: 0, date: Date())
            }
        
        allImages = images.isEmpty ? [initialFile] : images
        currentIndex = allImages.firstIndex(where: { $0.url == initialFile.url }) ?? 0
    }
}

// Wrapper for async loading
struct AsyncImageLoaderView: View {
    let file: VideoFile
    let initialFile: VideoFile
    let networkService: AppNetworkService?
    let server: ServerConfig?
    @ObservedObject private var settings = AppSettings.shared
    
    let isCurrent: Bool
    let onImageReady: (UIImage) -> Void
    let onTap: () -> Void
    
    @State private var localURL: URL?
    @State private var isLoading = false
    @State private var errorMsg: String?
    
    var body: some View {
        Group {
            if let url = localURL {
                ZoomableImageView(
                    url: url,
                    isCurrent: isCurrent,
                    onImageReady: onImageReady,
                    onTap: onTap
                )
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                Color(UIColor.systemBackground) // Should trigger load
            }
        }
        .appErrorAlert(
            message: $errorMsg,
            title: NSLocalizedString("Couldn't open preview", comment: "")
        )
        .onAppear {
            if localURL == nil && errorMsg == nil {
                loadContent()
            }
        }
    }
    
    private func loadContent() {
        // Optimisation: If this is the initial file we already downloaded, use it!
        if file.name == initialFile.name, initialFile.url.isFileURL, FileManager.default.fileExists(atPath: initialFile.url.path) {
            self.localURL = initialFile.url
            return
        }
        
        // If it's a local file (file scheme), just use it
        if !file.isRemote, file.url.isFileURL, FileManager.default.fileExists(atPath: file.url.path) {
            self.localURL = file.url
            return
        }
        
        // Remote download needed
        guard let service = networkService, let srv = server else {
            if file.url.isFileURL, FileManager.default.fileExists(atPath: file.url.path) {
                self.localURL = file.url
                return
            }
            self.errorMsg = "No network service"
            return
        }
        
        isLoading = true
        Task {
            do {
                // Determine path for download
                // WebDAV/SMB path handling... 
                // We need the RELATIVE path on the server.
                // file.url from listFiles might be a full URL (WebDAV) or constructed path (SMB)
                // Reconstructing path can be tricky. 
                // Simplest way: The 'list' command usually returns VideoFiles with valid server URLs or paths?
                // In the unified remote file list: files have URLs related to the share?
                // Let's rely on the URL string logic used in downloadFile?
                
                // Wait, NetworkService.downloadFile expects 'path'.
                // For SMB, it's share/path.
                // For WebDAV, it's relative path.
                // The VideoFile.url MIGHT match what we need or we might need to extract path.
                // Let's assume file.url.path (standard file path behavior) is what we need?
                // Actually WebDAVManager.listFiles returns full URLs.
                // SMBManager ... let's check.
                
                // Hack: If we pass the 'path' context to ImagePreviewView it ensures correctness?
                // Or we can just try to use the file.url.path?
                
                // Let's assume file.name is sufficient if we knew the parent path?
                // But we don't have parent path here easily unless passed.
                // WE SHOULD TRY TO EXTRACT IT or PASS IT.
                
                // BETTER: We can infer the path from the URL structure or just attempt download.
                // Re-using AppNetworkService.downloadFile is best.
                // It takes 'at path: String'.
                
                // let path = file.url.path // Unused
                // let downloadPath = file.url.absoluteString // Unused
                
                // Actually, let's pass the PARENT path of the list? No, files can be anywhere?
                // Usually files in context are siblings.
                // We can just use file.url.path.
                
                let localURL: URL
                if settings.enableRemoteFileCache {
                    localURL = try await RemoteFileCacheService.shared.fetchFile(
                        server: srv,
                        remotePath: file.remoteDownloadPath,
                        fileName: file.name
                    )
                } else {
                    localURL = try await service.downloadFile(server: srv, at: file.remoteDownloadPath)
                }
                
                await MainActor.run {
                    self.localURL = localURL
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMsg = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// Helper view for displaying image
// Helper view for displaying image with Zoom/Pan support
struct ZoomableImageView: View {
    let url: URL
    let isCurrent: Bool
    let onImageReady: (UIImage) -> Void
    let onTap: () -> Void // Callback for single tap
    
    @State private var image: UIImage?
    
    var body: some View {
        GeometryReader { geometry in
            if let img = image {
                ZoomableScrollView(image: img, onTap: onTap)
                    .onAppear { if isCurrent { onImageReady(img) } }
                    .onChange(of: isCurrent) { active in
                        if active { onImageReady(img) }
                    }
            } else {
                VStack {
                    ProgressView()
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear {
                    // Load image asynchronously
                    DispatchQueue.global(qos: .userInitiated).async {
                        if let data = try? Data(contentsOf: url),
                           let uiImage = UIImage(data: data) {
                            DispatchQueue.main.async {
                                self.image = uiImage
                            }
                        }
                    }
                }
            }
        }
    }
}

// Wrapper for UIScrollView to handle zooming
// Wrapper for UIScrollView to handle zooming
struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    
    func makeUIView(context: Context) -> LayoutHandlingScrollView {
        let scrollView = LayoutHandlingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        
        // Add Display Image
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit // Visual fallback
        imageView.tag = 999 
        scrollView.addSubview(imageView)
        scrollView.displayImageView = imageView
        
        // Double tap
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        
        // Single tap (for controls)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap) // Wait for double tap to fail
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }
    
    func updateUIView(_ uiView: LayoutHandlingScrollView, context: Context) {
        // Update image if changed
        if uiView.displayImageView?.image != image {
            uiView.displayImageView?.image = image
            uiView.displayImageView?.sizeToFit()
            uiView.isInitialLayout = true // Trigger re-layout
            uiView.setNeedsLayout()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableScrollView
        var initialContentOffset: CGPoint = .zero
        
        init(_ parent: ZoomableScrollView) {
            self.parent = parent
        }
        
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return scrollView.viewWithTag(999)
        }
        
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Let the subclass handle centering in layoutSubviews or via helper
            if let customScroll = scrollView as? LayoutHandlingScrollView {
                customScroll.centerImage()
            }
        }
        
        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            parent.onTap()
        }
        
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard
                let scrollView = gesture.view as? LayoutHandlingScrollView,
                let imageView = scrollView.displayImageView
            else {
                return
            }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                // If zoomed in, zoom out to fit
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let targetScale = targetZoomScale(for: scrollView, imageView: imageView)
                let zoomRect = zoomRectForScale(
                    scale: targetScale,
                    center: point,
                    imageView: imageView,
                    scrollView: scrollView
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
        
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
        
        func targetZoomScale(for scrollView: UIScrollView, imageView: UIImageView) -> CGFloat {
            let fitScale = max(scrollView.minimumZoomScale, 0.01)
            let widthFillScale = scrollView.bounds.width / max(imageView.bounds.width, 1)
            let heightFillScale = scrollView.bounds.height / max(imageView.bounds.height, 1)
            let fillScale = max(widthFillScale, heightFillScale)
            let smartScale = max(fitScale * 2.5, fillScale, 1.0)
            return min(scrollView.maximumZoomScale, smartScale)
        }

        func zoomRectForScale(
            scale: CGFloat,
            center: CGPoint,
            imageView: UIImageView,
            scrollView: UIScrollView
        ) -> CGRect {
            var zoomRect = CGRect.zero
            zoomRect.size.height = scrollView.bounds.height / scale
            zoomRect.size.width = scrollView.bounds.width / scale

            let constrainedCenter = CGPoint(
                x: min(max(center.x, 0), imageView.bounds.width),
                y: min(max(center.y, 0), imageView.bounds.height)
            )

            zoomRect.origin.x = constrainedCenter.x - (zoomRect.size.width / 2.0)
            zoomRect.origin.y = constrainedCenter.y - (zoomRect.size.height / 2.0)
            return zoomRect
        }
    }
}

// Custom ScrollView to handle layout timing issues
class LayoutHandlingScrollView: UIScrollView {
    var displayImageView: UIImageView?
    var isInitialLayout = true
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        guard let imageView = displayImageView else { return }
        
        if isInitialLayout && bounds.width > 0 && bounds.height > 0 && imageView.image != nil {
            isInitialLayout = false
            
            // Set frame to image size to allow correct zooming logic
            imageView.frame = CGRect(origin: .zero, size: imageView.image!.size)
            
            // Calculate Min Scale to FIT
            let widthScale = bounds.width / imageView.image!.size.width
            let heightScale = bounds.height / imageView.image!.size.height
            let minScale = min(widthScale, heightScale)
            
            // Rule:
            // If image is smaller than screen, minScale > 1. We might want to cap minScale at 1.0 to not upscale small images?
            // User compliant: "Not adapt to screen". Usually implies large images not fitting.
            // If large image: minScale < 1.0. We want to start there.
            
            minimumZoomScale = minScale
            maximumZoomScale = max(minScale * 3.0, 3.0) // Allow at least 3x
            
            zoomScale = minScale
            
            centerImage()
        }
        
        // Always center during scrolling/zooming if needed
        centerImage()
    }
    
    func centerImage() {
        guard let imageView = displayImageView else { return }
        
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame
        
        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2.0
        } else {
            frameToCenter.origin.x = 0
        }
        
        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2.0
        } else {
            frameToCenter.origin.y = 0
        }
        
        imageView.frame = frameToCenter
    }
}
