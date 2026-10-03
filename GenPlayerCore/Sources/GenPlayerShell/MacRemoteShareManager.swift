#if os(macOS)
import SwiftUI
import GenPlayerCore
import AppKit

public class MacRemoteShareManager: ObservableObject {
    public static let shared = MacRemoteShareManager()
    
    @Published public var isDownloading = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var errorMessage: String?
    @Published public var showError = false
    
    private var downloadTask: Task<Void, Never>?
    
    private init() {}
    
    public func shareRemoteFile(server: ServerConfig, path: String, action: @escaping (URL) -> Void) {
        if isDownloading { return }
        
        isDownloading = true
        downloadProgress = 0.0
        
        downloadTask = Task { @MainActor in
            do {
                let localURL = try await AppNetworkService.shared.downloadFile(server: server, at: path) { current, total in
                    Task { @MainActor in
                        if total > 0 {
                            self.downloadProgress = Double(current) / Double(total)
                        }
                    }
                }
                
                if Task.isCancelled { return }
                
                isDownloading = false
                action(localURL)
                
            } catch {
                if Task.isCancelled { return }
                isDownloading = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
    
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }
}

public struct MacRemoteShareOverlayModifier: ViewModifier {
    @ObservedObject var manager = MacRemoteShareManager.shared
    
    public func body(content: Content) -> some View {
        content
            .overlay {
                if manager.isDownloading {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView(value: manager.downloadProgress, total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(width: 200)
                            
                            Text(platformShellString("Downloading temporary copy..."))
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            Button(platformShellString("Cancel")) {
                                manager.cancelDownload()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(24)
                        .background(Color(NSColor.windowBackgroundColor))
                        .cornerRadius(12)
                        .shadow(radius: 10)
                    }
                }
            }
            .alert(isPresented: $manager.showError) {
                Alert(
                    title: Text(platformShellString("Download Failed")),
                    message: Text(manager.errorMessage ?? ""),
                    dismissButton: .default(Text(platformShellString("OK")))
                )
            }
    }
}

public extension View {
    func macRemoteShareOverlay() -> some View {
        self.modifier(MacRemoteShareOverlayModifier())
    }
}
#endif
