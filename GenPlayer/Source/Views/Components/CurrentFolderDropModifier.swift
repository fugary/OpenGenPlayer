import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct CurrentFolderDropModifier: ViewModifier {
    let isEnabled: Bool
    let onDropPayload: (String) -> Void
    
    init(isEnabled: Bool = true, onDropPayload: @escaping (String) -> Void) {
        self.isEnabled = isEnabled
        self.onDropPayload = onDropPayload
    }
    
    func body(content: Content) -> some View {
        content.background(
            CurrentFolderDropView(isEnabled: isEnabled, onDropPayload: onDropPayload)
        )
    }
}

private struct CurrentFolderDropView: UIViewRepresentable {
    let isEnabled: Bool
    let onDropPayload: (String) -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let dropInteraction = UIDropInteraction(delegate: context.coordinator)
        view.addInteraction(dropInteraction)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onDropPayload = onDropPayload
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var isEnabled = false
        var onDropPayload: ((String) -> Void)?
        
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            isEnabled && session.hasItemsConforming(toTypeIdentifiers: [UTType.plainText.identifier])
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            // Keep operation as move to suppress the green plus badge.
            UIDropProposal(operation: isEnabled ? .move : .cancel)
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            DragStateManager.shared.endDrag()
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            // Freeze acceptance and destination before asynchronous loading / session cleanup.
            guard isEnabled, let onDropPayload else { return }
            for dragItem in session.items {
                let provider = dragItem.itemProvider
                guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { continue }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let payload = object as? String else { return }
                    DispatchQueue.main.async {
                        onDropPayload(payload)
                    }
                }
            }
        }
    }
}

extension View {
    func onCurrentFolderDropTarget(isEnabled: Bool = true, perform: @escaping (String) -> Void) -> some View {
        modifier(CurrentFolderDropModifier(isEnabled: isEnabled, onDropPayload: perform))
    }
}

#if os(iOS)
/// Attach to the grid container itself, rather than a UIKit background sibling.
/// Folder cards remain the more specific drop destinations inside the grid.
private struct GridCurrentFolderDropDelegate: DropDelegate {
    let isEnabled: Bool
    let onDropPayload: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isEnabled ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isEnabled else { return false }
        let providers = info.itemProviders(for: [UTType.plainText])
        guard !providers.isEmpty else { return false }
        // Capture the destination before the drag state or navigation changes.
        let receivePayload = onDropPayload
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = object as? String else { return }
                DispatchQueue.main.async {
                    receivePayload(payload)
                }
            }
        }
        DragStateManager.shared.endDrag()
        return true
    }
}

extension View {
    func onGridCurrentFolderDropTarget(isEnabled: Bool, perform: @escaping (String) -> Void) -> some View {
        onDrop(of: [UTType.plainText], delegate: GridCurrentFolderDropDelegate(
            isEnabled: isEnabled,
            onDropPayload: perform
        ))
    }
}
#endif
