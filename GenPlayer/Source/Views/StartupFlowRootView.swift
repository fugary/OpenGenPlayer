import SwiftUI
import GenPlayerShell

struct StartupFlowRootView: View {
    let appLanguage: String

    var body: some View {
        AppStartupFlowRootView(appLanguage: appLanguage) {
            #if os(macOS)
            MainSplitView()
            #else
            MainTabView(appLanguage: appLanguage)
            #endif
        }
    }
}
