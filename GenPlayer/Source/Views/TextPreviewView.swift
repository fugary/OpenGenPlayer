#if os(macOS)
import SwiftUI
struct TextPreviewView: View {
    let title: String
    let text: String
    var body: some View {
        ScrollView { Text(text).padding() }
    }
}
#else
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct TextPreviewView: View {
    let file: VideoFile
    @Environment(\.presentationMode) var presentationMode
    
    @State private var loadError: String?
    @State private var textContent: String = ""
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            
            VStack {
                // Header with Close Button
                // Header removed for standard navigation
                Spacer().frame(height: 1)
                
                // Content
                GeometryReader { _ in
                    // Use UITextView wrapper for selection/copy support
                    NativeTextView(text: textContent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal)
                }
            }
        }
        .appErrorAlert(
            message: $loadError,
            title: NSLocalizedString("Couldn't open preview", comment: "")
        )
        .onAppear {
            loadFileContent()
        }
        .navigationBarTitle(file.name, displayMode: .inline)
    }
    
    private func loadFileContent() {
        if !file.supportsTextPreview {
            loadError = "Preview not available for this file type."
            textContent = ""
            return
        }
        
        do {
            // Try reading with UTF-8
            textContent = try String(contentsOf: file.url, encoding: .utf8)
            loadError = nil
        } catch {
            // Fallback: Try MacOS Roman or ASCII if UTF-8 fails (common for some sub files)
            if let content = try? String(contentsOf: file.url, encoding: .windowsCP1252) {
                 textContent = content
                 loadError = nil
            } else {
                loadError = "Could not read text content.\n\(error.localizedDescription)"
                textContent = ""
            }
        }
    }
}

struct NativeTextView: UIViewRepresentable {
    let text: String
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.showsVerticalScrollIndicator = true
        // Allow text to be selectable
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}

#endif
