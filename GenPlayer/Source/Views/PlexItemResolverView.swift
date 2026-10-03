import SwiftUI

struct PlexItemResolverView: View {
    let server: ServerConfig
    let item: PlexItem
    var onExit: (() -> Void)? = nil
    let onPlay: (PlexItem) -> Void

    @State private var resolvedItem: PlexItem?
    @State private var loadingErrorMessage: String?

    var body: some View {
        ZStack {
            if let resolvedItem {
                PlexItemDetailView(
                    server: server,
                    item: resolvedItem,
                    onExit: onExit,
                    onPlay: onPlay
                )
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
            retryAction: loadItem
        )
        .onAppear {
            if resolvedItem == nil && loadingErrorMessage == nil {
                loadItem()
            }
        }
    }

    private func loadItem() {
        loadingErrorMessage = nil

        Task {
            do {
                if let resolved = try await PlexService.shared.resolveMetadataItem(server: server, item: item) {
                    await MainActor.run {
                        resolvedItem = resolved
                    }
                } else {
                    await MainActor.run {
                        loadingErrorMessage = PlexError.serverError(404).localizedDescription
                    }
                }
            } catch {
                if (error is CancellationError) || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled) {
                    return
                }
                await MainActor.run {
                    loadingErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
