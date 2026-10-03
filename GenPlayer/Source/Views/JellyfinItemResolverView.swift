import SwiftUI

struct JellyfinItemResolverView: View {
    let server: ServerConfig
    let itemId: String
    var onExit: (() -> Void)? = nil
    
    @Environment(\.presentationMode) private var presentationMode
    
    @State private var resolvedItem: JellyfinItem?
    @State private var loadingErrorMessage: String?
    
    var body: some View {
        ZStack {
            if let item = resolvedItem {
                JellyfinItemDetailView(server: server, item: item, onExit: onExit)
            } else {
                Color(UIColor.systemBackground)
                    .ignoresSafeArea()

                if loadingErrorMessage == nil {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                    }
                }
            }
        }
        .appErrorAlert(
            message: $loadingErrorMessage,
            title: NSLocalizedString("Failed to load details", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: loadItem,
            cancelAction: { presentationMode.wrappedValue.dismiss() }
        )
        .onAppear {
            if resolvedItem == nil && loadingErrorMessage == nil {
                loadItem()
            }
        }
    }
    
    private func loadItem() {
        loadingErrorMessage = nil
        guard let token = server.accessToken else { return }
        
        Task {
            do {
                let item = try await JellyfinService.shared.getItemDetails(server: server, itemId: itemId, token: token)
                await MainActor.run {
                    self.resolvedItem = item
                }
            } catch {
                if (error is CancellationError) || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled) {
                    return
                }
                await MainActor.run {
                    self.loadingErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
