#if os(tvOS)
import SwiftUI
import UIKit

/// UIKit reports the actual menu lifecycle; SwiftUI menu content isn't mounted
/// like an ordinary view and cannot reliably report presentation via onAppear.
@available(tvOS 17.0, *)
struct TVPlaybackNativeMenu: UIViewRepresentable {
    let title: String
    let systemImage: String
    let menu: UIMenu
    let onPresent: (UIContextMenuInteraction) -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> TVPlaybackMenuButton {
        let button = TVPlaybackMenuButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.configurationUpdateHandler = { button in
            var configuration = button.configuration ?? .plain()
            configuration.baseForegroundColor = button.isFocused ? .black : .white
            configuration.background.backgroundColor = button.isFocused ? .white : .white.withAlphaComponent(0.16)
            button.configuration = configuration
        }
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: TVPlaybackMenuButton, context: Context) {
        button.accessibilityLabel = title
        button.onPresent = onPresent
        button.onDismiss = onDismiss
        var configuration = button.configuration ?? .plain()
        configuration.image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
        button.configuration = configuration
        // Never replace a live native menu when playback metadata changes.
        if button.isHeld { button.pendingMenu = menu }
        else { button.menu = menu }
    }
}

@available(tvOS 17.0, *)
final class TVPlaybackMenuButton: UIButton {
    var onPresent: ((UIContextMenuInteraction) -> Void)?
    var onDismiss: (() -> Void)?
    var pendingMenu: UIMenu?

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onPresent?(interaction)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willEndFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        let finish = { [weak self] in
            guard let self else { return }
            self.onDismiss?()
            if let pending = self.pendingMenu {
                self.pendingMenu = nil
                self.menu = pending
            }
        }
        if let animator { animator.addCompletion(finish) }
        else { finish() }
    }
}
#endif
