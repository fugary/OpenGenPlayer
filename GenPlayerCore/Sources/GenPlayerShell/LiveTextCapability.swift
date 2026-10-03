import Foundation

#if canImport(VisionKit)
import VisionKit
#endif

public enum LiveTextCapability {
    /// Returns true if the current OS version and device hardware support VisionKit Live Text.
    public static var isSupported: Bool {
        #if os(tvOS)
        return false
        #elseif canImport(VisionKit)
        if #available(iOS 16.0, macOS 13.0, *) {
            return ImageAnalyzer.isSupported
        } else {
            return false
        }
        #else
        return false
        #endif
    }
}
