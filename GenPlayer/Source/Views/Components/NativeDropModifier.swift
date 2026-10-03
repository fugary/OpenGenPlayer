import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct NativeDropModifier: ViewModifier {
    let isFolder: Bool
    let onDropFilePath: (String) -> Void
    @State private var isTargeted: Bool = false
    
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted && isFolder ? Color.accentColor.opacity(0.2) : Color.clear)
                    .padding(.horizontal, -12) // Extend highlight beyond the content padding
                    .allowsHitTesting(false)
            )
#if os(iOS)
            // A background sibling can be hidden from hit testing by the List row's button.
            // Keep folders available for the entire system drag session, independent of UI-state timeouts.
            // The UIKit view passes ordinary touches through.
            .overlay(
                NativeDropView(isFolder: isFolder, isTargeted: $isTargeted, onDropFilePath: onDropFilePath)
                    .allowsHitTesting(isFolder)
            )
#else
            .background(
                NativeDropView(isFolder: isFolder, isTargeted: $isTargeted, onDropFilePath: onDropFilePath)
            )
#endif
    }
}

#if os(iOS)
/// Drop hit testing must not make this transparent overlay a touch target.
/// Folder drop availability is independent of the shared drag-state safety timeout.
private final class TouchPassthroughDropView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if event?.type == .touches {
            return false
        }
        return super.point(inside: point, with: event)
    }
}
#endif

private struct NativeDropView: UIViewRepresentable {
    let isFolder: Bool
    @Binding var isTargeted: Bool
    let onDropFilePath: (String) -> Void
    
    func makeUIView(context: Context) -> UIView {
#if os(iOS)
        let view = TouchPassthroughDropView()
#else
        let view = UIView()
#endif
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let dropInteraction = UIDropInteraction(delegate: context.coordinator)
        view.addInteraction(dropInteraction)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isFolder = isFolder
        context.coordinator.isTargetedBinding = $isTargeted
        context.coordinator.onDropFilePath = onDropFilePath
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, UIDropInteractionDelegate {
        var isFolder: Bool = false
        var isTargetedBinding: Binding<Bool>?
        var onDropFilePath: ((String) -> Void)?
        
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            return isFolder && session.hasItemsConforming(toTypeIdentifiers: [UTType.plainText.identifier])
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            if isFolder {
                return UIDropProposal(operation: .move)
            }
            return UIDropProposal(operation: .cancel)
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            if isFolder {
                isTargetedBinding?.wrappedValue = true
            }
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            isTargetedBinding?.wrappedValue = false
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            isTargetedBinding?.wrappedValue = false
#if os(iOS)
            DragStateManager.shared.endDrag()
#endif
        }
        
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            isTargetedBinding?.wrappedValue = false
            guard isFolder, let onDropFilePath else { return }
            
            for dragItem in session.items {
                let provider = dragItem.itemProvider
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    _ = provider.loadObject(ofClass: NSString.self) { string, error in
                        if let nsString = string as? NSString {
                            DispatchQueue.main.async {
                                onDropFilePath(nsString as String)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension View {
    func nativeListDropTarget(isFolder: Bool, perform: @escaping (String) -> Void) -> some View {
        self.modifier(NativeDropModifier(isFolder: isFolder, onDropFilePath: perform))
    }
}
