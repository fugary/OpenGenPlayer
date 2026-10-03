import Foundation

enum PlatformHelper {
    static var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #elseif os(macOS)
        return true
        #else
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        } else {
            return false
        }
        #endif
    }
}
