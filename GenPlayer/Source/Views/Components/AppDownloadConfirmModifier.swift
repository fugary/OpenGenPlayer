import SwiftUI

private struct AppDownloadConfirmOverlay: View {
    @Binding var isPresented: Bool
    let message: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        onCancel()
                        isPresented = false
                    }
                
                VStack(spacing: 20) {
                    Text(NSLocalizedString("Add to Download Queue", comment: ""))
                        .font(.headline)
                    
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    
                    HStack(spacing: 16) {
                        Button(action: {
                            onCancel()
                            isPresented = false
                        }) {
                            Text(NSLocalizedString("Cancel", comment: ""))
                                .frame(minWidth: 80)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        Button(action: {
                            onConfirm()
                            isPresented = false
                        }) {
                            Text(NSLocalizedString("Download", comment: ""))
                                .frame(minWidth: 80)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(24)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
                .shadow(radius: 10)
                .frame(maxWidth: 320)
            }
            .zIndex(999)
        }
    }
}

private struct AppDownloadConfirmModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content.overlay(
            AppDownloadConfirmOverlay(
                isPresented: $isPresented,
                message: message,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        )
    }
}

extension View {
    func appDownloadConfirmAlert(
        isPresented: Binding<Bool>,
        message: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(
            AppDownloadConfirmModifier(
                isPresented: isPresented,
                message: message,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        )
    }
}


