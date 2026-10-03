import SwiftUI

struct UnifiedSearchBar: View {
    @Binding var text: String
    var placeholder: String = "Search..."
    var onCancel: (() -> Void)? = nil
    var alwaysShowCancel: Bool = false
    var autoFocus: Bool = false
    
    // Internal state for tracking focus via onEditingChanged, compatible with iOS 14+
    @State private var isFocused: Bool = false
    @State private var hasAppeared: Bool = false
    

    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16, weight: .medium))
                
                if #available(iOS 15.0, *) {
                    InternalTextField(text: $text, placeholder: placeholder, autoFocus: autoFocus)
                        .onChange(of: text) { _ in 
                            // Propagate changes if needed, but binding handles it
                        }
                } else {
                    TextField(placeholder, text: $text, onEditingChanged: { editing in
                        isFocused = editing
                    })
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(.primary)
                    .accentColor(Color.accentColor)
                }
                
                if !text.isEmpty {
                    Button(action: {
                        text = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                ZStack {
                     // Adaptive system background for search bar
                     Capsule()
                        .fill(Color(.systemGray6))
                }
            )
            // Auto-focus logic using Introspect-like behavior or state hack for iOS 15 focus
            .onAppear {
                if autoFocus && !hasAppeared {
                    hasAppeared = true
                    // Delay slightly to ensure view transition is complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isFocused = true
                        // Note: Programmatic focus in pure SwiftUI pre-iOS 15 is hard without binding or Introspect.
                        // For iOS 15, we could use @FocusState, but we removed it for compatibility.
                        // We will rely on the user tapping for now unless we re-introduce FocusState with #available check.
                    }
                }
            }
            // Tap gesture to focus is limited in pure SwiftUI iOS 14 without Introspect,
            // so we rely on tapping the text field itself.
            
            if alwaysShowCancel || isFocused || !text.isEmpty {
                Button(NSLocalizedString("Cancel", comment: "")) {
                    if alwaysShowCancel {
                        // If always shown, generic cancel action (likely dismiss)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        onCancel?()
                    } else {
                        // Standard search bar behavior
                        text = ""
                        isFocused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        onCancel?()
                    }
                }
                .foregroundColor(.accentColor)
                .font(.system(size: 17))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .animation(.spring(), value: isFocused)
        .animation(.spring(), value: !text.isEmpty)
    }

}

// Preview to verify appearance
struct UnifiedSearchBar_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            VStack {
                UnifiedSearchBar(text: .constant("Test"))
                UnifiedSearchBar(text: .constant(""))
            }
        }
        .colorScheme(.dark)
    }
}

@available(iOS 15.0, *)
struct InternalTextField: View {
    @Binding var text: String
    let placeholder: String
    let autoFocus: Bool
    
    @FocusState private var isFocused: Bool
    @State private var hasAppeared = false
    
    var body: some View {
        TextField(placeholder, text: $text)
            .focused($isFocused)
            .textFieldStyle(PlainTextFieldStyle())
            .foregroundColor(.primary)
            .accentColor(Color.accentColor)
            .submitLabel(.search)
            .onAppear {
                if autoFocus && !hasAppeared {
                    hasAppeared = true
                    // Delay to allow view transition
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        isFocused = true
                    }
                }
            }
    }
}
