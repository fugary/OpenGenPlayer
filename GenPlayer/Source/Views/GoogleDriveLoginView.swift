import SwiftUI
import AuthenticationServices
import GenPlayerCore
import GenPlayerShell

struct GoogleDriveLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkService = AppNetworkService.shared

    var existingServer: ServerConfig?

    @State private var serverName: String = "Google Drive"
    @State private var isAuthenticating: Bool = false
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false
    @State private var authSession: ASWebAuthenticationSession?
    @State private var authContextProvider: WebAuthContextProvider?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Server Name", comment: ""))) {
                    TextField(NSLocalizedString("e.g., My Google Drive", comment: ""), text: $serverName)
                }

                Section(
                    header: Text(NSLocalizedString("Google Account Authorization", comment: "")),
                    footer: VStack(alignment: .leading, spacing: 6) {
                        Text(NSLocalizedString("Sign in securely with your Google Account via official Google authentication.", comment: ""))
                        Text(NSLocalizedString("Cloud Drive Beta Disclaimer", comment: ""))
                            .foregroundColor(.orange)
                    }
                ) {
                    VStack(spacing: 16) {
                        ServerTypeIconBadge(type: .googledrive, size: 48, iconSize: 26)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)

                        Text(NSLocalizedString("Connect to Google Drive", comment: ""))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Text(NSLocalizedString("Access your videos, photos, and documents stored in Google Drive with high-speed streaming.", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Button(action: {
                            startGoogleSignIn()
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
                                Text(isAuthenticating ? NSLocalizedString("Signing in...", comment: "") : NSLocalizedString("Sign in with Google", comment: ""))
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.96, green: 0.70, blue: 0.12))
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
            .navigationTitle(existingServer != nil ? NSLocalizedString("Edit Google Drive", comment: "") : NSLocalizedString("Add Google Drive", comment: ""))
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

    private func startGoogleSignIn() {
        isAuthenticating = true
        let pkce = GoogleDriveManager.generatePKCE()

        guard let authURL = GoogleDriveManager.buildAuthorizationURL(challenge: pkce.challenge) else {
            isAuthenticating = false
            errorMessage = NSLocalizedString("Failed to build authorization URL", comment: "")
            showErrorAlert = true
            return
        }

        let contextProvider = WebAuthContextProvider()
        self.authContextProvider = contextProvider

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: GoogleDriveManager.callbackScheme) { callbackURL, error in
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
                    let tokenResponse = try await GoogleDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
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

    private func saveServerWithTokens(_ tokens: GoogleDriveManager.TokenResponse) {
        var name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "Google Drive" {
            name = tokens.displayName.isEmpty ? "Google Drive" : "Google Drive - \(tokens.displayName)"
        }

        var server: ServerConfig
        if var existing = existingServer {
            existing.name = name
            existing.accessToken = tokens.accessToken
            if !tokens.refreshToken.isEmpty {
                existing.passwordSecret = tokens.refreshToken
            }
            server = existing
            networkService.updateServer(server)
        } else {
            server = ServerConfig(
                name: name,
                address: "www.googleapis.com",
                port: 443,
                useSSL: true,
                type: .googledrive,
                passwordSecret: tokens.refreshToken,
                accessToken: tokens.accessToken
            )
            networkService.addServer(server)
        }

        networkService.recordServerAccess(server.id)
        dismiss()
    }
}
