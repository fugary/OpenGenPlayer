import SwiftUI

#if os(macOS)
import AppKit

struct MacClickableView<Content: View>: NSViewRepresentable {
    let action: () -> Void
    let content: Content

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    func makeNSView(context: Context) -> MacClickableHostingView<Content> {
        let view = MacClickableHostingView(rootView: content)
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MacClickableHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.action = action
    }
}

class MacClickableHostingView<Content: View>: NSHostingView<Content> {
    var action: (() -> Void)?
    var mouseDownPoint: NSPoint = .zero
    
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        super.mouseDown(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        let mouseUpPoint = event.locationInWindow
        let dx = abs(mouseUpPoint.x - mouseDownPoint.x)
        let dy = abs(mouseUpPoint.y - mouseDownPoint.y)
        
        // If it was a short click (within drag threshold), trigger action
        if dx < 16 && dy < 16 {
            action?()
        }
        super.mouseUp(with: event)
    }
}

public struct MacPointerHoverModifier: ViewModifier {
    @State private var isPushed = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && !isPushed {
                    NSCursor.pointingHand.push()
                    isPushed = true
                } else if !hovering && isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}

extension View {
    public func macPointerHover() -> some View {
        self.modifier(MacPointerHoverModifier())
    }
}
#endif
