import Foundation

/// Simulator preview budget, independent of Retina scale and source resolution.
enum MPVSoftwareRenderSize {
    static func fit(_ size: CGSize, maximumDimension: CGFloat = 1280) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1,
              maximumDimension.isFinite, maximumDimension >= 2 else { return nil }
        let scale = min(1, maximumDimension / max(size.width, size.height))
        return CGSize(width: max(2, (size.width * scale).rounded(.down)),
                      height: max(2, (size.height * scale).rounded(.down)))
    }
}
