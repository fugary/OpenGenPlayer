import SwiftUI

struct PreviewSheetContainer<Content: View>: View {
    @Environment(\.presentationMode) private var presentationMode

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationView {
            content
                .navigationBarItems(leading: closeButton)
        }
        .navigationViewStyle(.stack)
    }

    private var closeButton: some View {
        Button(action: {
            presentationMode.wrappedValue.dismiss()
        }) {
            AppToolbarIcon(systemName: "xmark", style: .secondary)
        }
        .accessibilityLabel(Text(NSLocalizedString("Close Preview", comment: "")))
    }
}

struct UnsupportedPreviewView: View {
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            Text(NSLocalizedString("Unsupported file type", comment: ""))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .navigationBarTitle(NSLocalizedString("Unsupported file type", comment: ""), displayMode: .inline)
    }
}
