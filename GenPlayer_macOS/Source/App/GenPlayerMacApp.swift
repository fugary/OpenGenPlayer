#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import GenPlayerShell
import GenPlayerCore

struct GenPlayerMacRootView: View {
    @AppStorage("userTheme") private var userTheme: String = "System"
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    var body: some View {
        AppStartupFlowRootView(appLanguage: appLanguage) {
            MainSplitView()
        }
        .environment(\.locale, Locale(identifier: platformResolvedLanguage(for: appLanguage)))
        .background(MacMainWindowAccessor())
        .onChange(of: userTheme) { newTheme in
            updateAppearance(theme: newTheme)
        }
        .onAppear {
            updateAppearance(theme: userTheme)
            AppIconService.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macServerPlaybackSyncRequest)) { notification in
            guard let payload = notification.object as? MacServerPlaybackSyncPayload else { return }
            handleServerSyncPayload(payload)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            MacPlayerWindowManager.shared.openLocalFileURL(url)
                        }
                    }
                }
            }
            return true
        }
        .onOpenURL { url in
            DispatchQueue.main.async {
                MacPlayerWindowManager.shared.openLocalFileURL(url, hideMainWindow: true)
            }
        }
    }
    
    private func handleServerSyncPayload(_ payload: MacServerPlaybackSyncPayload) {
        guard let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString == payload.serverId }) else {
            return
        }
        
        Task {
            await MacMediaReportingService.shared.reportPlayback(payload: payload, server: server)
        }
    }

    private func updateAppearance(theme: String) {
        let appearance: NSAppearance? = {
            if theme == "Light" { return NSAppearance(named: .aqua) }
            if theme == "Dark" { return NSAppearance(named: .darkAqua) }
            return nil
        }()
        NSApp.appearance = appearance
    }
}
#endif
