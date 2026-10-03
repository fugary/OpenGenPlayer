#if os(iOS) || os(macOS)
import SwiftUI

public struct SubtitleBrowserView: View {
    public let sources: [SubtitleBrowserSource]
    public let currentTime: Double
    public let canSeek: Bool
    public let onSeek: (Double) -> Void
    public let onClose: () -> Void
    public let trackSelections: [SubtitleBrowserTrackSelection]
    @StateObject private var model = SubtitleBrowserModel()
    @State private var selectedID = ""
    @State private var followsPlayback = true
    @State private var retryID = UUID()
    @State private var returnID = UUID()

    public init(sources: [SubtitleBrowserSource], currentTime: Double, canSeek: Bool,
                onSeek: @escaping (Double) -> Void, onClose: @escaping () -> Void,
                trackSelections: [SubtitleBrowserTrackSelection] = []) {
        self.sources = sources
        self.currentTime = currentTime
        self.canSeek = canSeek
        self.onSeek = onSeek
        self.onClose = onClose
        self.trackSelections = trackSelections
    }

    private var trackSelection: SubtitleBrowserTrackSelection? {
        trackSelections.first { $0.id == selectedID } ?? trackSelections.first
    }
    private var source: SubtitleBrowserSource? {
        if let trackSelection { return trackSelection.source }
        return sources.first { $0.id == selectedID } ?? sources.first
    }
    private var offset: Double { source?.offset ?? 0 }
    private var anchorID: String? { model.document.anchorID(at: currentTime, offset: offset) }
    private var activeIDs: Set<String> { model.document.activeIDs(at: currentTime, offset: offset) }
    private var searchTerm: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(platformShellString("SB.Title")).font(.headline)
                Spacer()
                Button(platformShellString("Done"), action: onClose)
            }
            .padding()

            if let trackSelection {
                if trackSelections.count > 1 {
                    Picker(platformShellString("Subtitle"), selection: Binding(
                        get: { trackSelection.id }, set: { selectedID = $0; followsPlayback = true }
                    )) {
                        ForEach(trackSelections) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.bottom, 8)
                }
                Picker(platformShellString("Subtitle"), selection: Binding(
                    get: { trackSelection.selectedTrackID }, set: trackSelection.select
                )) {
                    ForEach(trackSelection.options) { option in
                        Text(option.title).tag(option.id).disabled(!option.isEnabled)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            } else if sources.count > 1 {
                Picker(platformShellString("Subtitle"), selection: Binding(
                    get: { source?.id ?? "" }, set: { selectedID = $0; followsPlayback = true }
                )) {
                    ForEach(sources) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            } else if let source {
                Text(source.title).font(.subheadline).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }

            SubtitleBrowserSearchField(text: $model.query)
                #if os(macOS)
                .frame(height: 28)
                #else
                .frame(height: 44)
                #endif
                .padding(.horizontal, 12).padding(.vertical, 8)

            HStack {
                Text(String(format: platformShellString("SB.Count"), model.matches.count))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(platformShellString("SB.Current")) {
                    model.query = ""
                    followsPlayback = true
                    returnID = UUID()
                }
                .disabled(model.document.entries.isEmpty)
            }
            .padding(.horizontal).padding(.bottom, 8)
            if model.document.isPartial {
                Text(platformShellString(model.document.partialStatusKey)).font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            Divider()
            content
        }
        .task(id: "\(source?.requestKey ?? "")|\(retryID)") { await model.load(source) }
        .onChange(of: source?.id) { _ in followsPlayback = true }
        .onChange(of: model.query) { value in if !value.isEmpty { followsPlayback = false } }
        .onDisappear { model.invalidate() }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else if let status = model.statusKey {
            VStack(spacing: 12) {
                Spacer()
                Text(platformShellString(status)).foregroundColor(.secondary).multilineTextAlignment(.center)
                if model.canRetry { Button(platformShellString("Retry")) { retryID = UUID() } }
                Spacer()
            }.padding().frame(maxWidth: .infinity)
        } else if model.matches.isEmpty {
            VStack { Spacer(); Text(platformShellString("SB.NoMatches")).foregroundColor(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(model.matches) { entry in
                    Button {
                        onSeek(SubtitleBrowserDocument.seekTime(for: entry, offset: offset))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: activeIDs.contains(entry.id) ? "speaker.wave.2.fill" : "play.circle")
                                Text(Self.timeLabel(max(0, entry.start + offset))).monospacedDigit()
                            }
                            .font(.caption).foregroundColor(.secondary)
                            highlighted(entry.text).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSeek || model.loadedKey != source?.requestKey)
                    .listRowBackground(activeIDs.contains(entry.id) ? Color.accentColor.opacity(0.16) : Color.clear)
                    .id(entry.id)
                }
                .listStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { _ in followsPlayback = false })
                #if os(macOS)
                .background(SubtitleBrowserScrollObserver { followsPlayback = false })
                #endif
                .onAppear { follow(proxy) }
                .onChange(of: anchorID) { _ in follow(proxy) }
                .onChange(of: model.updateID) { _ in follow(proxy) }
                .onChange(of: returnID) { _ in follow(proxy) }
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard followsPlayback, searchTerm.isEmpty, let anchorID else { return }
        proxy.scrollTo(anchorID, anchor: .center)
    }

    private func highlighted(_ string: String) -> Text {
        guard !searchTerm.isEmpty else { return Text(string) }
        var result = Text("")
        var start = string.startIndex
        while start < string.endIndex,
              let match = string.range(of: searchTerm, options: [.caseInsensitive, .diacriticInsensitive], range: start..<string.endIndex),
              !match.isEmpty {
            result = result + Text(String(string[start..<match.lowerBound]))
                + Text(String(string[match])).bold().foregroundColor(.accentColor)
            start = match.upperBound
        }
        return result + Text(String(string[start...]))
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let value = Int(min(seconds, Double(Int32.max)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

#if os(macOS)
import AppKit

private struct SubtitleBrowserSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = platformShellString("SB.Search")
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SubtitleBrowserSearchField
        init(_ parent: SubtitleBrowserSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
    }
}

/// Wheel events are user scrolling; programmatic scrollTo produces none. Scope to this list only.
private struct SubtitleBrowserScrollObserver: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> Observer { Observer(onScroll: onScroll) }
    func updateNSView(_ view: Observer, context: Context) { view.onScroll = onScroll }
    final class Observer: NSView {
        var onScroll: () -> Void
        private var monitor: Any?
        init(onScroll: @escaping () -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .scrollWheel {
                    if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.onScroll() }
                } else if [115, 116, 119, 121, 125, 126].contains(event.keyCode),
                          !(self.window?.firstResponder is NSTextView) {
                    self.onScroll()
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#else
import UIKit

private struct SubtitleBrowserSearchField: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.placeholder = platformShellString("SB.Search")
        bar.delegate = context.coordinator
        bar.autocapitalizationType = .none
        return bar
    }
    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.parent = self
        if bar.text != text { bar.text = text }
    }
    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SubtitleBrowserSearchField
        init(_ parent: SubtitleBrowserSearchField) { self.parent = parent }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { parent.text = searchText }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    }
}
#endif
#endif
