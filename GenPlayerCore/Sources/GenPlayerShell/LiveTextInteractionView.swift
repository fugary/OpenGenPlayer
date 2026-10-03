import SwiftUI

#if os(iOS)
import UIKit
#if canImport(VisionKit)
import VisionKit
#endif

public struct LiveTextInteractionView: View {
    public let image: UIImage
    @Binding public var isAnalyzing: Bool

    public init(image: UIImage, isAnalyzing: Binding<Bool> = .constant(false)) {
        self.image = image
        self._isAnalyzing = isAnalyzing
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            LiveTextInteractionView_iOS(image: image, isAnalyzing: $isAnalyzing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class LiveTextHostUIImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

@available(iOS 16.0, *)
struct LiveTextInteractionView_iOS: UIViewRepresentable {
    let image: UIImage
    @Binding var isAnalyzing: Bool

    func makeUIView(context: Context) -> LiveTextHostUIImageView {
        let imageView = LiveTextHostUIImageView()
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        #if canImport(VisionKit)
        if ImageAnalyzer.isSupported {
            let interaction = ImageAnalysisInteraction()
            imageView.addInteraction(interaction)
            context.coordinator.interaction = interaction
            context.coordinator.analyze(image: image, interaction: interaction)
        }
        #endif

        return imageView
    }

    func updateUIView(_ uiView: LiveTextHostUIImageView, context: Context) {
        if uiView.image !== image {
            uiView.image = image
            #if canImport(VisionKit)
            if ImageAnalyzer.isSupported, let interaction = context.coordinator.interaction {
                context.coordinator.analyze(image: image, interaction: interaction)
            }
            #endif
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isAnalyzing: $isAnalyzing)
    }

    class Coordinator: NSObject {
        @Binding var isAnalyzing: Bool
        #if canImport(VisionKit)
        var interaction: ImageAnalysisInteraction?
        private let analyzer = ImageAnalyzer()

        init(isAnalyzing: Binding<Bool>) {
            self._isAnalyzing = isAnalyzing
        }

        func analyze(image: UIImage, interaction: ImageAnalysisInteraction) {
            isAnalyzing = true
            Task {
                do {
                    let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                    let analysis = try await analyzer.analyze(image, orientation: .up, configuration: config)
                    await MainActor.run {
                        interaction.analysis = analysis
                        interaction.preferredInteractionTypes = [.textSelection, .dataDetectors]
                        interaction.selectableItemsHighlighted = true
                        self.isAnalyzing = false
                    }
                } catch {
                    print("[LiveText] Analysis failed: \(error)")
                    await MainActor.run {
                        self.isAnalyzing = false
                    }
                }
            }
        }
        #else
        init(isAnalyzing: Binding<Bool>) {
            self._isAnalyzing = isAnalyzing
        }
        #endif
    }
}

#elseif os(macOS)
import AppKit
#if canImport(VisionKit)
import VisionKit
#endif

public struct LiveTextInteractionView: View {
    public let image: NSImage
    @Binding public var isAnalyzing: Bool

    public init(image: NSImage, isAnalyzing: Binding<Bool> = .constant(false)) {
        self.image = image
        self._isAnalyzing = isAnalyzing
    }

    public var body: some View {
        if #available(macOS 13.0, *) {
            LiveTextInteractionView_macOS(image: image, isAnalyzing: $isAnalyzing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class LiveTextHostImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    #if canImport(VisionKit)
    override func layout() {
        super.layout()
        if #available(macOS 13.0, *) {
            for subview in subviews {
                if subview is ImageAnalysisOverlayView {
                    subview.frame = bounds
                }
            }
        }
    }
    #endif
}

@available(macOS 13.0, *)
struct LiveTextInteractionView_macOS: NSViewRepresentable {
    let image: NSImage
    @Binding var isAnalyzing: Bool

    func makeNSView(context: Context) -> LiveTextHostImageView {
        let imageView = LiveTextHostImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        #if canImport(VisionKit)
        if ImageAnalyzer.isSupported {
            let overlay = ImageAnalysisOverlayView()
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = imageView.bounds
            overlay.trackingImageView = imageView
            imageView.addSubview(overlay)
            context.coordinator.overlay = overlay

            context.coordinator.analyze(image: image, overlay: overlay)
        }
        #endif

        return imageView
    }

    func updateNSView(_ nsView: LiveTextHostImageView, context: Context) {
        if nsView.image != image {
            nsView.image = image
            #if canImport(VisionKit)
            if ImageAnalyzer.isSupported, let overlay = context.coordinator.overlay {
                context.coordinator.analyze(image: image, overlay: overlay)
            }
            #endif
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isAnalyzing: $isAnalyzing)
    }

    class Coordinator: NSObject {
        @Binding var isAnalyzing: Bool
        #if canImport(VisionKit)
        var overlay: ImageAnalysisOverlayView?
        private let analyzer = ImageAnalyzer()

        init(isAnalyzing: Binding<Bool>) {
            self._isAnalyzing = isAnalyzing
        }

        func analyze(image: NSImage, overlay: ImageAnalysisOverlayView) {
            isAnalyzing = true
            Task {
                do {
                    let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                    let analysis = try await analyzer.analyze(image, orientation: .up, configuration: config)
                    await MainActor.run {
                        overlay.analysis = analysis
                        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
                        overlay.selectableItemsHighlighted = true
                        self.isAnalyzing = false
                    }
                } catch {
                    print("[LiveText] Analysis failed: \(error)")
                    await MainActor.run {
                        self.isAnalyzing = false
                    }
                }
            }
        }
        #else
        init(isAnalyzing: Binding<Bool>) {
            self._isAnalyzing = isAnalyzing
        }
        #endif
    }
}

#elseif os(tvOS)
public struct LiveTextInteractionView: View {
    @Binding public var isAnalyzing: Bool
    public init(isAnalyzing: Binding<Bool> = .constant(false)) {
        self._isAnalyzing = isAnalyzing
    }
    public var body: some View {
        EmptyView()
    }
}
#endif
