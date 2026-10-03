import SwiftUI
import AuthenticationServices
import GenPlayerCore
import GenPlayerShell

struct OneDriveLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkService = AppNetworkService.shared

    var existingServer: ServerConfig?

    @State private var serverName: String = "OneDrive"
    @State private var isAuthenticating: Bool = false
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false
    @State private var authSession: ASWebAuthenticationSession?
    @State private var authContextProvider: WebAuthContextProvider?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Server Name", comment: ""))) {
                    TextField(NSLocalizedString("e.g., My OneDrive", comment: ""), text: $serverName)
                }

                Section(
                    header: Text(NSLocalizedString("Microsoft Account Authorization", comment: "")),
                    footer: VStack(alignment: .leading, spacing: 6) {
                        Text(NSLocalizedString("Sign in securely with your personal, work, or school Microsoft Account via official Microsoft authentication.", comment: ""))
                        Text(NSLocalizedString("Cloud Drive Beta Disclaimer", comment: ""))
                            .foregroundColor(.orange)
                    }
                ) {
                    VStack(spacing: 16) {
                        ServerTypeIconBadge(type: .onedrive, size: 48, iconSize: 26)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)

                        Text(NSLocalizedString("Connect to OneDrive", comment: ""))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Text(NSLocalizedString("Access your videos, photos, and documents stored in OneDrive with high-speed streaming.", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Button(action: {
                            startMicrosoftSignIn()
                        }) {
                            HStack {
                                if isAuthenticating {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .padding(.trailing, 6)
                                } else {
                                    Image(systemName: "lock.shield")
                                        .font(.headline)
                                }
                                Text(isAuthenticating ? NSLocalizedString("Signing in...", comment: "") : NSLocalizedString("Sign in with Microsoft", comment: ""))
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAuthenticating)
                        .padding(.vertical, 8)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(existingServer != nil ? NSLocalizedString("Edit OneDrive", comment: "") : NSLocalizedString("Add OneDrive", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        authSession?.cancel()
                        dismiss()
                    }
                }
            }
            .alert(isPresented: $showErrorAlert) {
                Alert(
                    title: Text(NSLocalizedString("Error", comment: "")),
                    message: Text(errorMessage ?? NSLocalizedString("Unknown Error", comment: "")),
                    dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                )
            }
            .onAppear {
                if let existing = existingServer {
                    serverName = existing.name
                }
            }
        }
    }

    private func startMicrosoftSignIn() {
        isAuthenticating = true
        let pkce = OneDriveManager.generatePKCE()

        guard let authURL = OneDriveManager.buildAuthorizationURL(challenge: pkce.challenge) else {
            isAuthenticating = false
            errorMessage = "Failed to build authorization URL"
            showErrorAlert = true
            return
        }

        let contextProvider = WebAuthContextProvider()
        self.authContextProvider = contextProvider

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "genplayer") { callbackURL, error in
            DispatchQueue.main.async {
                self.isAuthenticating = false
            }

            if let error = error {
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    return
                }
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.showErrorAlert = true
                }
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async {
                    self.errorMessage = NSLocalizedString("Authorization code not returned.", comment: "")
                    self.showErrorAlert = true
                }
                return
            }

            Task {
                do {
                    let tokenResponse = try await OneDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
                    await MainActor.run {
                        self.saveServerWithTokens(tokenResponse)
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.showErrorAlert = true
                    }
                }
            }
        }

        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        self.authSession = session
        session.start()
    }

    private func saveServerWithTokens(_ tokens: OneDriveManager.TokenResponse) {
        var name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "OneDrive" {
            name = tokens.displayName.isEmpty ? "OneDrive" : "OneDrive - \(tokens.displayName)"
        }

        var server: ServerConfig
        if var existing = existingServer {
            existing.name = name
            existing.accessToken = tokens.accessToken
            existing.passwordSecret = tokens.refreshToken
            server = existing
            networkService.updateServer(server)
        } else {
            server = ServerConfig(
                name: name,
                address: "graph.microsoft.com",
                port: 443,
                useSSL: true,
                type: .onedrive,
                passwordSecret: tokens.refreshToken,
                accessToken: tokens.accessToken
            )
            networkService.addServer(server)
        }

        networkService.recordServerAccess(server.id)
        dismiss()
    }
}

// MARK: - Presentation Context Provider

#if os(iOS)
final class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return ASPresentationAnchor()
        }
        return window
    }
}
#elseif os(macOS)
final class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
#endif
