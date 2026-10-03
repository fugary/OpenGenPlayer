import SwiftUI
import UniformTypeIdentifiers

// MARK: - Multi-Drag View Modifier (Pure SwiftUI, no UIKit bridging)

/// A ViewModifier that wraps SwiftUI's `.onDrag` to support multi-file drag payloads.
/// When in selection mode with selected files, the drag payload includes all selected IDs/paths.
/// On iOS 15+, a custom drag preview with a count badge is shown.
struct MultiDragModifier: ViewModifier {
    let file: VideoFile
    let isSelectionMode: Bool
    let selectedFileIDs: Set<String>
    let isLocalFile: Bool
    
    private var dragPayload: String {
        if isSelectionMode && selectedFileIDs.contains(file.id) {
            let allIds = Array(selectedFileIDs)
            return allIds.joined(separator: "\n")
        }
        return isLocalFile ? file.url.path : file.id
    }
    
    private var selectedCount: Int {
        if isSelectionMode && selectedFileIDs.contains(file.id) {
            return selectedFileIDs.count
        }
        return 1
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            if selectedCount > 1 {
                content.onDrag {
                    DragStateManager.shared.startDrag(paths: dragPayload.split(separator: "\n").map { String($0) })
                    return NSItemProvider(object: dragPayload as NSString)
                } preview: {
                    dragPreview
                }
            } else {
                content.onDrag {
                    DragStateManager.shared.startDrag(paths: dragPayload.split(separator: "\n").map { String($0) })
                    return NSItemProvider(object: dragPayload as NSString)
                }
            }
        } else {
            content.onDrag {
                DragStateManager.shared.startDrag(paths: dragPayload.split(separator: "\n").map { String($0) })
                return NSItemProvider(object: dragPayload as NSString)
            }
        }
    }
    
    /// Custom drag preview: file icon + name, with a count badge for multi-select
    private var dragPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: file.iconName)
                .foregroundColor(file.iconColor)
                .font(.title3)
            
            Text(file.name)
                .font(.callout)
                .lineLimit(1)
                .foregroundColor(.primary)
            
            if selectedCount > 1 {
                Text("\(selectedCount)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }
}

extension View {
    func nativeMultiDrag(file: VideoFile, isSelectionMode: Bool, selectedFileIDs: Set<String>, isLocalFile: Bool = false) -> some View {
        self.modifier(MultiDragModifier(file: file, isSelectionMode: isSelectionMode, selectedFileIDs: selectedFileIDs, isLocalFile: isLocalFile))
    }
}
