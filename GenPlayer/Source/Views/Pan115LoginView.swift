import SwiftUI
import GenPlayerCore
import GenPlayerShell

struct Pan115LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkService = AppNetworkService.shared

    var existingServer: ServerConfig?

    @State private var serverName: String = "115"
    @State private var cookieText: String = ""
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false

    // QR Code states
    @State private var qrSession: Pan115Manager.QRCodeSessionInfo?
    @State private var qrStatus: Pan115Manager.QRCodeStatus = .waiting
    @State private var isPollingQR: Bool = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Server Name", comment: ""))) {
                    TextField(NSLocalizedString("e.g., My 115 Cloud", comment: ""), text: $serverName)
                }

                Section(header: Text(NSLocalizedString("Scan with 115 Mobile App", comment: ""))) {
                    VStack(spacing: 16) {
                        if let qr = qrSession {
                            AsyncImage(url: qr.qrCodeURL) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                        .frame(width: 200, height: 200)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .interpolation(.none)
                                        .scaledToFit()
                                        .frame(width: 200, height: 200)
                                        .cornerRadius(12)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        )
                                case .failure:
                                    VStack(spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.largeTitle)
                                            .foregroundColor(.orange)
                                        Text(NSLocalizedString("Failed to load QR code", comment: ""))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Button(NSLocalizedString("Retry", comment: "")) {
                                            loadQRCode()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .frame(width: 200, height: 200)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)

                            Text(qrStatusDescription)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)

                            Button(action: loadQRCode) {
                                Label(NSLocalizedString("Refresh QR Code", comment: ""), systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 200)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(existingServer != nil ? NSLocalizedString("Edit 115 Cloud", comment: "") : NSLocalizedString("Add 115 Cloud", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        stopPolling()
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
                    cookieText = existing.passwordSecret ?? existing.accessToken ?? ""
                }
                loadQRCode()
            }
            .onDisappear {
                stopPolling()
            }
        }
    }

    private var qrStatusDescription: String {
        switch qrStatus {
        case .waiting:
            return NSLocalizedString("Please scan the QR code with 115 App", comment: "")
        case .scanned:
            return NSLocalizedString("Scanned! Please confirm authorization on your phone.", comment: "")
        case .success:
            return NSLocalizedString("Login successful!", comment: "")
        case .expired:
            return NSLocalizedString("QR code expired. Tap to reload.", comment: "")
        case .error(let msg):
            return msg
        }
    }

    private func loadQRCode() {
        stopPolling()
        qrSession = nil
        qrStatus = .waiting

        Task {
            do {
                let session = try await Pan115Manager.shared.startQRCodeLogin()
                await MainActor.run {
                    self.qrSession = session
                    self.startPolling(session: session)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showErrorAlert = true
                }
            }
        }
    }

    private func startPolling(session: Pan115Manager.QRCodeSessionInfo) {
        stopPolling()
        isPollingQR = true

        pollTask = Task {
            while !Task.isCancelled && isPollingQR {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }

                let status = await Pan115Manager.shared.pollQRCodeStatus(
                    uid: session.uid,
                    time: session.time,
                    sign: session.sign
                )

                await MainActor.run {
                    self.qrStatus = status
                    switch status {
                    case .success(let cookie):
                        self.stopPolling()
                        self.saveServerWithCookie(cookie)
                    case .expired:
                        self.stopPolling()
                    case .error(let err):
                        self.stopPolling()
                        self.errorMessage = err
                        self.showErrorAlert = true
                    case .waiting, .scanned:
                        break
                    }
                }
            }
        }
    }

    private func stopPolling() {
        isPollingQR = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func saveServerWithCookie(_ cookie: String) {
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "115" : serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        var server: ServerConfig
        if var existing = existingServer {
            existing.name = name
            existing.passwordSecret = cookie
            existing.accessToken = cookie
            server = existing
            networkService.updateServer(server)
        } else {
            server = ServerConfig(
                name: name,
                address: "https://115.com",
                port: 443,
                useSSL: true,
                type: .pan115,
                passwordSecret: cookie,
                accessToken: cookie
            )
            networkService.addServer(server)
        }
        dismiss()
    }
}
