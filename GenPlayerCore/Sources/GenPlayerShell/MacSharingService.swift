#if os(macOS)
import AppKit
import SwiftUI
import GenPlayerCore

public struct MacSharingService {
    
    /// Presents the macOS share sheet (NSSharingServicePicker) for the given items.
    /// - Parameters:
    ///   - items: The items (e.g., URLs, strings, images) to share.
    ///   - view: The view to present the popover from. If nil, it tries to find the current window's content view.
    public static func share(items: [Any], from view: NSView? = nil) {
        let picker = NSSharingServicePicker(items: items)
        
        guard let targetView = view ?? NSApp.keyWindow?.contentView else {
            return
        }
        
        // Present near the mouse cursor or the center of the view if cursor isn't available
        let mouseLocation = targetView.window?.mouseLocationOutsideOfEventStream ?? .zero
        let locationInView = targetView.convert(mouseLocation, from: nil)
        
        var rect = NSRect(origin: locationInView, size: CGSize(width: 1, height: 1))
        
        // If the mouse is way outside, fallback to center
        if !targetView.bounds.contains(locationInView) {
            rect = NSRect(x: targetView.bounds.midX, y: targetView.bounds.midY, width: 1, height: 1)
        }
        
        picker.show(relativeTo: rect, of: targetView, preferredEdge: .minY)
    }
    
    /// Reveals the file in Finder. For local files only.
    public static func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    /// Opens the file using the default application, or for HTTP URLs tries player apps (IINA, VLC, Infuse) before falling back to browser.
    public static func openInAnotherApp(url: URL) {
        if url.isFileURL {
            NSWorkspace.shared.open(url)
        } else {
            let playerBundleIDs = [
                "com.colliderli.iina",      // IINA
                "org.videolan.vlc",         // VLC
                "com.firecore.infuse",      // Infuse
                "com.Eltima.ElmediaPlayer"  // Elmedia
            ]
            for bundleID in playerBundleIDs {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
                    if NSWorkspace.shared.open([url], withAppBundleIdentifier: bundleID, options: [], additionalEventParamDescriptor: nil, launchIdentifiers: nil) {
                        return
                    }
                }
            }
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies a string to system clipboard.
    public static func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
#endif
