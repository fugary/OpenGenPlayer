import SwiftUI

/// A custom view modifier that conditionally applies the modern `.searchable` native navigation bar
/// search functionality on iOS 15+, while gracefully falling back to a custom implementation (or doing nothing)
/// on iOS 14 and below.
struct SearchableModifier: ViewModifier {
    let text: Binding<String>
    let prompt: String
    
    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
        } else {
            // iOS 14 fallback: does nothing here, relying on the calling view
            // to provide a manual search button in the toolbar instead.
            content
        }
    }
}

extension View {
    /// Conditionally adds a native navigation bar search field on iOS 15+.
    /// For iOS 14, this is a no-op and you should provide a manual search button.
    func compatSearchable(text: Binding<String>, prompt: String) -> some View {
        self.modifier(SearchableModifier(text: text, prompt: prompt))
    }
}
