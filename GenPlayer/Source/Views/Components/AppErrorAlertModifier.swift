import SwiftUI

private struct AppErrorAlertPresenter: View {
    @Binding var message: String?
    let title: String
    let retryTitle: String?
    let retryAction: (() -> Void)?
    let cancelAction: (() -> Void)?

    private var isPresented: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { isPresented in
                if !isPresented {
                    message = nil
                    cancelAction?()
                }
            }
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert(isPresented: isPresented) {
                if let retryAction {
                    return Alert(
                        title: Text(title),
                        message: Text(message ?? ""),
                        primaryButton: .default(Text(retryTitle ?? NSLocalizedString("Retry", comment: ""))) {
                            message = nil
                            retryAction()
                        },
                        secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: ""))) {
                            message = nil
                            cancelAction?()
                        }
                    )
                }

                return Alert(
                    title: Text(title),
                    message: Text(message ?? ""),
                    dismissButton: .default(Text(NSLocalizedString("OK", comment: ""))) {
                        message = nil
                        cancelAction?()
                    }
                )
            }
    }
}

private struct AppErrorAlertModifier: ViewModifier {
    @Binding var message: String?
    let title: String
    let retryTitle: String?
    let retryAction: (() -> Void)?
    let cancelAction: (() -> Void)?

    func body(content: Content) -> some View {
        content.background(
            AppErrorAlertPresenter(
                message: $message,
                title: title,
                retryTitle: retryTitle,
                retryAction: retryAction,
                cancelAction: cancelAction
            )
        )
    }
}

extension View {
    func appErrorAlert(
        message: Binding<String?>,
        title: String,
        retryTitle: String? = nil,
        retryAction: (() -> Void)? = nil,
        cancelAction: (() -> Void)? = nil
    ) -> some View {
        modifier(
            AppErrorAlertModifier(
                message: message,
                title: title,
                retryTitle: retryTitle,
                retryAction: retryAction,
                cancelAction: cancelAction
            )
        )
    }
}
