import SwiftUI
import UniformTypeIdentifiers

struct FileDropTargetModifier: ViewModifier {
    let file: VideoFile
    let onDropFilePath: (String) -> Void
    @State private var isTargeted: Bool = false
    
    func body(content: Content) -> some View {
        content
            // Overlay a highlight color when a drop is hovering over a folder
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted && file.type == .folder ? Color.accentColor.opacity(0.2) : Color.clear)
                    .padding(.horizontal, -12) // Extend highlight beyond the content padding
            )
            .onDrop(of: [UTType.plainText], delegate: FileDropDelegate(
                file: file,
                isTargeted: $isTargeted,
                onDropFilePath: onDropFilePath
            ))
    }
}

/// DropDelegate that uses .move operation to suppress the green "+" badge.
private struct FileDropDelegate: DropDelegate {
    let file: VideoFile
    @Binding var isTargeted: Bool
    let onDropFilePath: (String) -> Void
    
#if os(iOS)
    func validateDrop(info: DropInfo) -> Bool {
        // Files are not destinations. Let the enclosing current-folder target handle them.
        file.type == .folder && info.hasItemsConforming(to: [UTType.plainText])
    }
#endif

    func dropEntered(info: DropInfo) {
        if file.type == .folder {
            isTargeted = true
        }
    }
    
    func dropExited(info: DropInfo) {
        isTargeted = false
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // .move removes the green "+" badge during drag
        return DropProposal(operation: file.type == .folder ? .move : .cancel)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard file.type == .folder else { return false }
        
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else {
            return false
        }
        
        _ = provider.loadObject(ofClass: NSString.self) { string, error in
            if let nsString = string as? NSString {
                DispatchQueue.main.async {
                    onDropFilePath(nsString as String)
                }
            }
        }
        return true
    }
}

extension View {
    func onFileDropTarget(file: VideoFile, perform: @escaping (String) -> Void) -> some View {
        self.modifier(FileDropTargetModifier(file: file, onDropFilePath: perform))
    }
}
