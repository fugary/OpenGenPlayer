#if os(macOS)
import SwiftUI
import GenPlayerCore

public struct MacFilePreviewSheet: View {
    let url: URL
    let file: VideoFile
    @ObservedObject var loadingState = MacPreviewLoadingState()
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    let onClose: () -> Void

    @State private var liveTextImage: NSImage?
    @State private var liveTextImageURL: URL?
    @State private var showingLiveText = false

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if file.supportsTextPreview {
                    MacTextPreviewView(url: url)
                } else if !file.canOpenInPreviewSheet {
                    macUnsupportedPrompt
                } else {
                    MacQuickLookPreview(url: url)
                }

                if loadingState.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                
                if file.type == .image {
                    HStack {
                        if let onPrevious = onPrevious {
                            Button(action: onPrevious) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Circle().fill(Color.black.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 16)
                        }
                        
                        Spacer()
                        
                        if let onNext = onNext {
                            Button(action: onNext) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Circle().fill(Color.black.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 16)
                        }
                    }
                    .disabled(loadingState.isLoading)
                }
            }
            .frame(minWidth: 500, minHeight: 400)
            
            if file.canOpenInPreviewSheet {
                HStack {
                    if file.type == .image && LiveTextCapability.isSupported {
                        Button {
                            showingLiveText = true
                        } label: {
                            Label(platformShellString("Live Text"), systemImage: "text.viewfinder")
                        }
                        .disabled(loadingState.isLoading || liveTextImage == nil || liveTextImageURL != url)
                        .padding(.leading)
                    }
                    Spacer()
                    Button("Open in Default App") {
                        NSWorkspace.shared.open(url)
                        onClose()
                    }
                    .disabled(loadingState.isLoading)
                    .padding()
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .task(id: "\(url.absoluteString)|\(loadingState.isLoading)") {
            liveTextImage = nil
            liveTextImageURL = nil
            showingLiveText = false
            guard file.type == .image, LiveTextCapability.isSupported,
                  !loadingState.isLoading else { return }
            let sourceURL = url
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: sourceURL)
            }.value
            guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return }
            liveTextImage = image
            liveTextImageURL = sourceURL
        }
        .sheet(isPresented: $showingLiveText) {
            if let image = liveTextImage {
                PlayerLiveTextViewer(image: image, onDismiss: { showingLiveText = false })
                    .frame(minWidth: 600, minHeight: 500)
            }
        }
        .alert(isPresented: Binding(
            get: { loadingState.errorMessage != nil },
            set: { if !$0 { loadingState.errorMessage = nil } }
        )) {
            Alert(
                title: Text(platformShellString("Couldn't open preview")),
                message: Text(loadingState.errorMessage ?? ""),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
    }
    
    @ViewBuilder
    private var macUnsupportedPrompt: some View {
        VStack(spacing: 20) {
            Image(systemName: file.iconName)
                .font(.system(size: 64))
                .foregroundColor(file.usesStyledFormatTile ? file.iconColor : .secondary)
            
            Text(platformShellString("Preview Not Available"))
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(platformShellString("This file type isn't supported for in-app preview."))
                .foregroundColor(.secondary)
                
            Button(action: {
                NSWorkspace.shared.open(url)
                onClose()
            }) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text(platformShellString("Open in Default App"))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct MacTextPreviewView: View {
    let url: URL
    @State private var textContent: String = ""
    @State private var errorMessage: String?
    
    var body: some View {
        ZStack {
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
            } else {
                TextEditor(text: .constant(textContent))
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
        }
        .onAppear {
            do {
                textContent = try String(contentsOf: url, encoding: .utf8)
            } catch {
                errorMessage = "Failed to load text: \(error.localizedDescription)"
            }
        }
    }
}
#endif
