#if os(macOS)
import SwiftUI
import AppKit

/// Both browsing headers reserve the same space as their overlay, from the first layout.
enum MacBrowserToolbarMetrics {
    static let topInset: CGFloat = 52
    static let rowHeight: CGFloat = 52
    static let bottomInset: CGFloat = 8
    static let totalHeight = topInset + rowHeight + bottomInset
}

/// Keep the existing layout footprint while delegating interaction drawing to AppKit.
/// Shared only by macOS browsing controls; layout and action state stay with each page.
struct MacToolbarButton: View {
    let systemImage: String
    let title: String
    var role: ButtonRole? = nil
    var diameter: CGFloat = 36
    var symbolSize: CGFloat = 17
    var symbolWeight: NSFont.Weight = .medium
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            MacNativeToolbarButton(
                systemImage: systemImage, title: title, role: role,
                symbolSize: symbolSize, symbolWeight: symbolWeight, action: action
            )
            .frame(width: diameter, height: diameter)
        } else {
            Button(role: role, action: action) {
                Image(systemName: systemImage)
                    .font(Font(NSFont.systemFont(ofSize: symbolSize, weight: symbolWeight)))
            }
            .buttonStyle(MacHeaderButtonStyle(diameter: diameter, isDestructive: role == .destructive))
            .help(title)
        }
    }
}

@available(macOS 26.0, *)
private struct MacNativeToolbarButton: NSViewRepresentable {
    let systemImage: String
    let title: String
    let role: ButtonRole?
    let symbolSize: CGFloat
    let symbolWeight: NSFont.Weight
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.performAction(_:)))
        button.setButtonType(.momentaryPushIn)
        // borderShape alone did not change the toolbar bezel's hover artwork.
        // Select AppKit's circular bezel so the control itself owns the round shape.
        button.bezelStyle = .circular
        button.borderShape = .circle
        button.isBordered = true
        // The group owns the glass. AppKit draws only the button's native feedback.
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .vertical)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        button.contentTintColor = role == .destructive ? .systemRed : nil
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolSize, weight: symbolWeight))
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        button.target = nil
        button.action = nil
        coordinator.action = {}
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            action()
        }
    }
}

enum MacToolbarSide: Hashable {
    case leading, trailing
}

struct MacToolbarControlBoundsKey: PreferenceKey {
    static var defaultValue: [MacToolbarSide: Anchor<CGRect>] = [:]

    static func reduce(value: inout [MacToolbarSide: Anchor<CGRect>], nextValue: () -> [MacToolbarSide: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Keep the title centered when it fits, and within the actual gap between controls otherwise.
/// Anchor preferences work on macOS 12 without adopting the macOS 13 Layout API.
struct MacToolbarTitlePlacement<Title: View>: ViewModifier {
    let title: Title

    func body(content: Content) -> some View {
        content
            .frame(minHeight: 40)
            .backgroundPreferenceValue(MacToolbarControlBoundsKey.self) { anchors in
                GeometryReader { geometry in
                    let leading = anchors[.leading].map { geometry[$0].maxX } ?? 24
                    let trailing = anchors[.trailing].map { geometry[$0].minX } ?? (geometry.size.width - 24)
                    let start = leading + 12
                    let end = max(start, trailing - 12)
                    let width = min(360, end - start)
                    let center = min(max(geometry.size.width / 2, start + width / 2), end - width / 2)
                    title
                        .frame(width: width)
                        .position(x: center, y: geometry.size.height / 2)
                }
            }
    }
}

/// The containing trailing group keeps its right anchor as this slot expands left.
struct MacExpandableToolbarSearch: View {
    @Binding var text: String
    @Binding var isExpanded: Bool

    private var effectivelyExpanded: Bool {
        isExpanded || !text.isEmpty
    }

    private var effectivelyExpandedBinding: Binding<Bool> {
        Binding(
            get: { isExpanded || !text.isEmpty },
            set: { isExpanded = $0 }
        )
    }

    var body: some View {
        ZStack {
            MacNativeToolbarSearchField(text: $text, isExpanded: effectivelyExpandedBinding)
                .padding(.horizontal, effectivelyExpanded ? 4 : 0)
                .opacity(effectivelyExpanded ? 1 : 0)
                .allowsHitTesting(effectivelyExpanded)
                .accessibilityHidden(!effectivelyExpanded)

            MacToolbarButton(systemImage: "magnifyingglass", title: platformShellString("Search")) {
                isExpanded = true
            }
            .opacity(effectivelyExpanded ? 0 : 1)
            .disabled(effectivelyExpanded)
            .allowsHitTesting(!effectivelyExpanded)
            .accessibilityHidden(effectivelyExpanded)
        }
        .frame(width: effectivelyExpanded ? 240 : 36, height: 36)
    }
}

private struct MacNativeToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isExpanded: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        if let cell = field.cell as? NSSearchFieldCell {
            cell.cancelButtonCell?.target = context.coordinator
            cell.cancelButtonCell?.action = #selector(Coordinator.cancelButtonClicked(_:))
        }
        context.coordinator.searchField = field
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.searchField = field
        field.placeholderString = platformShellString("Search")
        field.setAccessibilityLabel(platformShellString("Search"))
        // Leave the field editor's marked text intact during Chinese/Japanese input.
        if field.stringValue != text,
           (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        field.isEnabled = isExpanded
        guard coordinator.expanded != isExpanded else { return }
        coordinator.expanded = isExpanded
        coordinator.generation += 1
        coordinator.removeClickMonitor()
        if isExpanded {
            let generation = coordinator.generation
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator,
                      coordinator.expanded, coordinator.generation == generation,
                      !field.isHiddenOrHasHiddenAncestor,
                      let window = field.window, window.isKeyWindow else { return }
                window.makeFirstResponder(field)
            }
            coordinator.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak field, weak coordinator] event in
                if let field, let coordinator, let window = field.window,
                   event.window === window,
                   !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    coordinator.requestCollapse()
                }
                return event
            }
        } else if field.currentEditor() != nil {
            field.window?.endEditing(for: field)
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.expanded = false
        coordinator.generation += 1
        coordinator.removeClickMonitor()
        coordinator.searchField = nil
        if let cell = field.cell as? NSSearchFieldCell {
            cell.cancelButtonCell?.target = nil
            cell.cancelButtonCell?.action = nil
        }
        field.delegate = nil
        field.target = nil
        field.action = nil
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacNativeToolbarSearchField
        var expanded = false
        var generation = 0
        var clickMonitor: Any?
        weak var searchField: NSSearchField?

        init(parent: MacNativeToolbarSearchField) { self.parent = parent }

        func removeClickMonitor() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        func requestCollapse() {
            guard parent.text.isEmpty else { return }
            let generation = generation
            // Finish dispatching the original click/delegate callback before updating SwiftUI.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.expanded, self.generation == generation else { return }
                guard self.parent.text.isEmpty else { return }
                self.parent.isExpanded = false
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard expanded, let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func searchChanged(_ field: NSSearchField) {
            // Also receive the native cancel cell's action when it clears the query.
            parent.text = field.stringValue
        }

        @objc func cancelButtonClicked(_ sender: Any?) {
            if let field = searchField {
                field.stringValue = ""
            }
            parent.text = ""
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            sender.stringValue = ""
            parent.text = ""
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSSearchField {
                parent.text = field.stringValue
            }
            requestCollapse()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
                if !parent.text.isEmpty {
                    if let field = control as? NSSearchField {
                        field.stringValue = ""
                    }
                    parent.text = ""
                    return true
                } else {
                    requestCollapse()
                    return true
                }
            }
            return false
        }
    }
}

struct MacToolbarGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // One glass surface per existing group; do not make the whole group a button.
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

// MARK: - Compatibility appearance for macOS before 26
struct MacHeaderButtonStyle: ButtonStyle {
    var diameter: CGFloat = 36
    var isDestructive = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isDestructive ? (isHovered ? .red : .red.opacity(0.85)) : (isHovered ? .primary : .secondary))
            .frame(width: diameter, height: diameter, alignment: .center)
            .contentShape(Circle())
            .background(
                Circle()
                    .fill(isHovered
                          ? (isDestructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.08))
                          : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovered = $0 }
            .macPointerHover()
    }
}

#endif
