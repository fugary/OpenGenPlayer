import SwiftUI
import Combine

/// Shared drag state manager that tracks when a drag operation is active.
/// `MultiDragModifier` sets the drag source path when a drag begins.
/// List views observe this to show/hide drop zones.
@MainActor
final class DragStateManager: ObservableObject {
    static let shared = DragStateManager()
    
    /// The source paths being dragged (full file paths, newline-separated in payload)
    @Published var dragSourcePaths: [String] = []
    
    /// Whether a drag is currently active
    var isDragging: Bool { !dragSourcePaths.isEmpty }
    
    private var clearTimer: Timer?
    
    private init() {}
    
    /// Called by MultiDragModifier when a drag starts
    func startDrag(paths: [String]) {
        dragSourcePaths = paths
        // Safety timeout: clear drag state after 30 seconds
        // (in case drop end is never reported)
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.endDrag()
            }
        }
    }
    
    /// Called when a drop is performed or drag ends
    func endDrag() {
        clearTimer?.invalidate()
        clearTimer = nil
        dragSourcePaths = []
    }
    
    /// Check if any dragged file comes from a different directory than `currentPath`
    func hasDragFromDifferentDirectory(currentPath: String) -> Bool {
        guard isDragging else { return false }
        
        let normalizedCurrent = normalizePath(currentPath)
        
        return dragSourcePaths.contains { path in
            let parentDir = NSString(string: path).deletingLastPathComponent
            let normalizedParent = normalizePath(parentDir)
            return normalizedParent != normalizedCurrent
        }
    }
    
    private func normalizePath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p = String(p.dropLast())
        }
        return URL(fileURLWithPath: p).standardizedFileURL.path
    }
}
