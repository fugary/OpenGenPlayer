#if os(iOS) || os(tvOS)
import UIKit
import Metal
import GenPlayerMPVBridge

/// UIKit owns the view geometry; the mpv VO thread owns drawable allocation.
/// Keep this surface for the lifetime of one engine, including rotations.
public final class MPVVideoSurfaceView: UIView {
    #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
    private let software = CALayer()
    #else
    private let metal = GPMPVMetalLayer()
    #endif
    private weak var engine: MPVPlaybackEngine?
    private var started = false

    public init(engine: MPVPlaybackEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
        software.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(software)
        #else
        metal.device = MTLCreateSystemDefaultDevice()
        metal.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metal)
        #endif
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func layoutSubviews() { super.layoutSubviews(); updateGeometry() }
    public override func didMoveToWindow() { super.didMoveToWindow(); updateGeometry() }

    private func updateGeometry() {
        guard let window, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window.screen.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        #if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
        software.frame = bounds
        CATransaction.commit()
        engine?.updateSoftwareSurface(size: CGSize(width: bounds.width * scale, height: bounds.height * scale)) { [weak self] image in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.software.contents = image
            CATransaction.commit()
        }
        #else
        metal.contentsScale = scale
        metal.frame = bounds
        CATransaction.commit()
        metal.targetPixelSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard !started else { return }
        metal.drawableSize = metal.targetPixelSize
        started = true
        engine?.attach(to: metal)
        #endif
    }
}
#endif
