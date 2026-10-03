import SwiftUI
import GenPlayerShell

struct PlatformRootView: View {
    let appLanguage: String

    var body: some View {
        #if os(iOS) || os(macOS)
        StartupFlowRootView(appLanguage: appLanguage)
        #elseif os(tvOS)
        TVMainView()
        #else
        EmptyView()
        #endif
    }
}
