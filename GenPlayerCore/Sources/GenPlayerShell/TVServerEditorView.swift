#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVServerEditorView: View {
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var networkService = AppNetworkService.shared

    let existingServer: ServerConfig?
    let prefilledServer: ServerConfig?

    @State private var type: ServerConfig.ServerType = .smb
    @State private var drafts: [ServerConfig.ServerType: ServerTypeDraft] = [:]
    @State private var vodSourceDrafts: [VODSourceConfig] = []

    @State private var verifiedUserId: String?
    @State private var plexPin: PlexLoginPin?
    @State private var isPlexAuthorizing = false
    @State private var plexPollingTask: Task<Void, Never>?
    @State private var pan115QRSession: Pan115Manager.QRCodeSessionInfo?
    @State private var pan115QRStatusText: String = ""
    @State private var pan115PollingTask: Task<Void, Never>?
    @State private var pairingServer: TVLocalPairingServer?
    @State private var pairingQRImage: UIImage?
    @State private var pairingStatusText: String = ""

    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var testFailed = false
    @State private var testTask: Task<Void, Never>?
    @State private var testResultAlert: TVTransientAlert?

    init(existingServer: ServerConfig?, prefilledServer: ServerConfig?) {
        self.existingServer = existingServer
        self.prefilledServer = prefilledServer

        let targetType: ServerConfig.ServerType
        var initialDrafts: [ServerConfig.ServerType: ServerTypeDraft] = [:]

        if let rawServer = existingServer ?? prefilledServer {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            targetType = server.type
            initialDrafts[server.type] = ServerTypeDraft.initial(for: server.type, existing: server)
        } else {
            targetType = .smb
            initialDrafts[.smb] = ServerTypeDraft.initial(for: .smb, existing: nil)
        }

        _vodSourceDrafts = State(initialValue: (existingServer ?? prefilledServer).map { $0.vodSources ?? [VODSourceConfig(id: $0.id, name: $0.name, address: $0.fullURL)] } ?? [])
        _type = State(initialValue: targetType)
        _drafts = State(initialValue: initialDrafts)
    }

    private var isEditing: Bool { existingServer != nil }

    private var spec: ServerFormSpec {
        ServerFormSpec.spec(for: type)
    }

    private var currentDraft: Binding<ServerTypeDraft> {
        Binding(
            get: {
                if let draft = drafts[type] {
                    return draft
                }
                return ServerTypeDraft.initial(for: type, existing: existingServer)
            },
            set: { newValue in
                drafts[type] = newValue
            }
        )
    }

    private var canSave: Bool {
        currentDraft.wrappedValue.isValidForSave(spec: spec)
            && (type != .vod || VODSourceEditor.valid(vodSourceDrafts))
    }

    private var defaultPortHint: String {
        let port = spec.defaultPort(useSSL: currentDraft.useSSL.wrappedValue)
        return "\(platformShellString("Default")): \(port)"
    }

    var body: some View {
        TVPageScrollView(
            title: platformShellString(isEditing ? "Edit Server" : "Add Server"),
            subtitle: nil,
            handlesExitCommand: true
        ) {
            TVServerTypeInlineSelector(selectedType: $type)

            TVTextFieldPanel(
                title: platformShellString("Server Name"),
                placeholder: spec.defaultServerName,
                text: currentDraft.name
            )

            if spec.authStyle == .pan115 {
                let hasAuth = !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasAuth {
                    TVInfoPanel(
                        title: "115",
                        message: platformShellString("Authorization successful!"),
                        systemImageName: "checkmark.shield.fill",
                        tintColor: .green
                    )

                    Button(action: {
                        currentDraft.password.wrappedValue = ""
                        loadPan115QRCode()
                    }) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Re-scan QR Code"),
                            systemImageName: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                } else {
                    Button(action: loadPan115QRCode) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString(pan115QRSession != nil ? "Refresh QR Code" : "QR Code Login"),
                            systemImageName: "qrcode"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()

                    if let qr = pan115QRSession {
                        TVFocusableStaticPanel {
                            VStack(spacing: 16) {
                                AsyncImage(url: qr.qrCodeURL) { phase in
                                    switch phase {
                                    case .empty:
                                        ProgressView().frame(width: 240, height: 240)
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .interpolation(.none)
                                            .scaledToFit()
                                            .frame(width: 240, height: 240)
                                            .cornerRadius(12)
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
                                    case .failure:
                                        VStack(spacing: 8) {
                                            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange).font(.title)
                                            Text(platformShellString("Failed to load QR code")).font(.caption).foregroundColor(.secondary)
                                        }
                                        .frame(width: 240, height: 240)
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                                Text(pan115QRStatusText.isEmpty ? platformShellString("Scan with 115 Mobile App") : pan115QRStatusText)
                                    .font(.headline)
                                    .foregroundColor(TVShellStyle.primary)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else if spec.authStyle == .onedrive || spec.authStyle == .googledrive {
                let hasAuth = !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasAuth {
                    TVInfoPanel(
                        title: type.displayName,
                        message: platformShellString("Authorization successful!"),
                        systemImageName: "checkmark.shield.fill",
                        tintColor: .green
                    )

                    Button(action: {
                        currentDraft.password.wrappedValue = ""
                        currentDraft.accessToken.wrappedValue = ""
                        startPairingServer(for: type)
                    }) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Re-scan QR Code"),
                            systemImageName: "qrcode"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                } else {
                    TVFocusableStaticPanel {
                        VStack(spacing: 18) {
                            if let qrImage = pairingQRImage {
                                Image(uiImage: qrImage)
                                    .resizable()
                                    .interpolation(.none)
                                    .scaledToFit()
                                    .frame(width: 260, height: 260)
                                    .background(Color.white)
                                    .cornerRadius(16)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                                    )
                                    .shadow(color: Color.black.opacity(0.4), radius: 12, y: 6)
                            } else {
                                ProgressView()
                                    .frame(width: 260, height: 260)
                            }

                            Text(platformShellString("Scan QR Code with Phone"))
                                .font(.headline)
                                .foregroundColor(TVShellStyle.primary)

                            Text(platformShellString("Scan the QR code with your phone camera to complete authorization."))
                                .font(.subheadline)
                                .foregroundColor(TVShellStyle.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)

                            if let server = pairingServer, !server.pairingURL.isEmpty {
                                VStack(spacing: 4) {
                                    Text(platformShellString("Or visit on phone/PC browser:"))
                                        .font(.caption)
                                        .foregroundColor(TVShellStyle.secondary)
                                    Text(server.pairingURL)
                                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                                        .foregroundColor(.blue)
                                }
                                .padding(.top, 2)
                            }

                            Text(pairingStatusText.isEmpty ? platformShellString("Waiting for authorization...") : pairingStatusText)
                                .font(.headline)
                                .foregroundColor(pairingStatusText == platformShellString("Authorization successful!") ? .green : TVShellStyle.primary)
                                .padding(.top, 4)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }

                    Button(action: { startPairingServer(for: type) }) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Refresh QR Code"),
                            systemImageName: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            } else if spec.authStyle == .iptv {
                TVTogglePanel(
                    title: platformShellString("HTTPS"),
                    subtitle: nil,
                    isOn: currentDraft.useSSL
                )

                TVTextFieldPanel(
                    title: platformShellString("Playlist URL or File Path"),
                    placeholder: spec.addressPlaceholder,
                    text: currentDraft.address
                )

                TVTextFieldPanel(
                    title: platformShellString("EPG URL (optional)"),
                    placeholder: "https://example.com/epg.xml.gz",
                    text: currentDraft.customEPGURL
                )
            } else if spec.authStyle == .vod {
                VODSourceEditor(sources: $vodSourceDrafts)
                    .onAppear {
                        if vodSourceDrafts.isEmpty {
                            vodSourceDrafts = [VODSourceConfig(name: currentDraft.wrappedValue.name, address: currentDraft.wrappedValue.address)]
                        }
                    }
                    .onChange(of: vodSourceDrafts) { sources in
                        currentDraft.wrappedValue.address = sources.first(where: \.isEnabled)?.address ?? ""
                    }
            } else {
                if spec.allowsSSL {
                    TVTogglePanel(
                        title: platformShellString("HTTPS"),
                        subtitle: nil,
                        isOn: currentDraft.useSSL
                    )
                }

                if spec.requiresAddressInput {
                    TVTextFieldPanel(
                        title: platformShellString("Address"),
                        placeholder: spec.addressPlaceholder,
                        text: currentDraft.address
                    )
                }

                if spec.requiresPortInput {
                    TVTextFieldPanel(
                        title: platformShellString("Port"),
                        placeholder: defaultPortHint,
                        text: currentDraft.portString
                    )
                }

                if spec.authStyle == .plex {
                    Button(action: startPlexLogin) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString(isPlexAuthorizing ? "Re-open Plex Login" : "Sign in with Plex"),
                            systemImageName: isPlexAuthorizing ? "arrow.clockwise" : "person.crop.circle.badge.checkmark"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    .disabled(currentDraft.address.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let plexPin {
                        TVPlexAuthorizationPanel(
                            pin: plexPin,
                            linkURL: PlexPinAuthorizationService.shared.linkURL(for: plexPin),
                            tintColor: type.tvAccentColor
                        )
                    } else if isPlexAuthorizing {
                        TVInfoPanel(
                            title: "Plex",
                            message: platformShellString("Waiting for Plex authorization..."),
                            systemImageName: "hourglass",
                            tintColor: type.tvAccentColor
                        )
                    } else if tvHasText(currentDraft.accessToken.wrappedValue) {
                        TVInfoPanel(
                            title: "Plex",
                            message: platformShellString("Token acquired. It will be saved and used automatically."),
                            systemImageName: "checkmark.shield.fill",
                            tintColor: .green
                        )
                    }

                    TVTextFieldPanel(
                        title: platformShellString("Access Token"),
                        placeholder: nil,
                        text: currentDraft.accessToken
                    )

                    TVInfoPanel(
                        title: "Plex",
                        message: platformShellString("Platform Shell TV Plex Token Hint"),
                        systemImageName: "key.fill"
                    )
                } else {
                    TVTextFieldPanel(
                        title: platformShellString("Username"),
                        placeholder: platformShellString("Username (optional)"),
                        text: currentDraft.username
                    )

                    TVTextFieldPanel(
                        title: platformShellString("Password"),
                        placeholder: platformShellString("Password (optional)"),
                        text: currentDraft.password,
                        secure: true
                    )

                    if spec.showsWorkgroup {
                        TVTextFieldPanel(
                            title: platformShellString("Workgroup (optional)"),
                            placeholder: platformShellString("Workgroup (optional)"),
                            text: currentDraft.workgroup
                        )
                    }
                }
            }

            if type.tvSupportsConnectionTest {
                Button(action: testConnection) {
                    TVMaintenanceButtonLabel(
                        title: platformShellString("Test Connection"),
                        systemImageName: isTesting ? "hourglass" : "network"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
                .disabled(!canSave || isTesting)
            }

            Button(action: saveServerAndDismiss) {
                TVMaintenanceButtonLabel(
                    title: platformShellString("Save"),
                    systemImageName: "checkmark.circle"
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .disabled(!canSave)
        }
        .onDisappear {
            testTask?.cancel()
            plexPollingTask?.cancel()
            pan115PollingTask?.cancel()
            stopPairingServer()
        }
        .onAppear {
            if (type == .onedrive || type == .googledrive) &&
               currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startPairingServer(for: type)
            }
        }
        .onChange(of: type) { newType in
            testTask?.cancel()
            cancelPlexLogin()
            pan115PollingTask?.cancel()
            pan115QRSession = nil
            stopPairingServer()

            if drafts[newType] == nil {
                drafts[newType] = ServerTypeDraft.initial(for: newType, existing: existingServer)
            }

            let newDraft = drafts[newType] ?? ServerTypeDraft.initial(for: newType, existing: existingServer)
            if newType == .pan115 {
                if newDraft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    loadPan115QRCode()
                }
            }
            if newType == .onedrive || newType == .googledrive {
                if newDraft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   newDraft.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    startPairingServer(for: newType)
                }
            }
        }
        .alert(item: $testResultAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
    }

    private func loadPan115QRCode() {
        pan115PollingTask?.cancel()
        pan115QRSession = nil
        pan115QRStatusText = platformShellString("Scan with 115 Mobile App")
        pan115PollingTask = Task {
            do {
                let session = try await Pan115Manager.shared.fetchQRCode()
                if Task.isCancelled { return }

                await MainActor.run {
                    self.pan115QRSession = session
                    self.pan115QRStatusText = platformShellString("Scan with 115 Mobile App")
                }

                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let statusResult = await Pan115Manager.shared.pollQRCodeStatus(session: session)
                    if Task.isCancelled { return }

                    var shouldStop = false
                    await MainActor.run {
                        switch statusResult {
                        case .waiting:
                            self.pan115QRStatusText = platformShellString("Scan with 115 Mobile App")
                        case .scanned:
                            self.pan115QRStatusText = platformShellString("Scanned. Please confirm on phone.")
                        case .success(let cookie):
                            self.pan115QRStatusText = platformShellString("Authorization successful!")
                            if !cookie.isEmpty {
                                self.currentDraft.password.wrappedValue = cookie
                                self.testSucceeded = true
                                self.testFailed = false
                                self.testResultAlert = TVTransientAlert(
                                    title: "115",
                                    message: platformShellString("Authorization successful!")
                                )
                            }
                            shouldStop = true
                        case .expired:
                            self.pan115QRStatusText = platformShellString("QR code expired. Click to reload.")
                            shouldStop = true
                        case .error(let err):
                            self.pan115QRStatusText = err
                            shouldStop = true
                        }
                    }

                    if shouldStop { break }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.pan115QRStatusText = error.localizedDescription
                }
            }
        }
    }

    private func startPairingServer(for serverType: ServerConfig.ServerType) {
        stopPairingServer()
        let server = TVLocalPairingServer(serverType: serverType)
        server.onPairingSuccess = { result in
            DispatchQueue.main.async {
                var d = self.drafts[serverType] ?? ServerTypeDraft.initial(for: serverType, existing: self.existingServer)
                d.password = result.refreshToken
                d.accessToken = result.accessToken
                if d.name.isEmpty || d.name == serverType.displayName {
                    d.name = result.displayName.isEmpty ? serverType.displayName : "\(serverType.displayName) - \(result.displayName)"
                }
                self.drafts[serverType] = d
                self.testSucceeded = true
                self.testFailed = false
                self.pairingStatusText = platformShellString("Authorization successful!")
                self.testResultAlert = TVTransientAlert(
                    title: platformShellString("Connection Successful"),
                    message: platformShellString("Authorization successful!")
                )
                self.stopPairingServer()
            }
        }
        let url = server.start()
        self.pairingServer = server
        if !url.isEmpty {
            self.pairingQRImage = TVQRCodeGenerator.image(from: url)
            self.pairingStatusText = platformShellString("Waiting for authorization...")
        } else {
            self.pairingQRImage = nil
            self.pairingStatusText = server.lastStatusMessage
        }
    }

    private func stopPairingServer() {
        pairingServer?.stop()
        pairingServer = nil
        pairingQRImage = nil
    }

    private func createServer() -> ServerConfig {
        var server = currentDraft.wrappedValue.buildServerConfig(type: type, id: existingServer?.id ?? UUID())
        if type == .vod {
            server.vodSources = vodSourceDrafts
            server.address = vodSourceDrafts.first(where: \.isEnabled)?.address.trimmingCharacters(in: .whitespacesAndNewlines) ?? server.address
        }
        let hydratedExisting = existingServer.map { AppNetworkService.shared.hydratedServer(from: $0) }

        let connectionSettingsChanged: Bool
        if let hydratedExisting {
            connectionSettingsChanged =
                hydratedExisting.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != server.address.lowercased() ||
                hydratedExisting.port != server.port ||
                hydratedExisting.useSSL != server.useSSL ||
                hydratedExisting.type != type ||
                hydratedExisting.username?.trimmingCharacters(in: .whitespacesAndNewlines) != server.username ||
                hydratedExisting.passwordSecret != server.passwordSecret ||
                hydratedExisting.workgroup?.trimmingCharacters(in: .whitespacesAndNewlines) != server.workgroup
        } else {
            connectionSettingsChanged = true
        }

        var finalAccessToken: String? = nil
        var finalUserId: String? = nil

        let currentAccessToken = currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Plex PIN authorization supplies the credential before any server probe succeeds.
        // Always use the current draft so testing/saving cannot discard it or restore an old token.
        if type == .plex {
            finalAccessToken = currentAccessToken
        } else if testSucceeded {
            finalAccessToken = currentAccessToken
            finalUserId = verifiedUserId
        } else if !testFailed && !connectionSettingsChanged, let existingServer, existingServer.type == type {
            finalAccessToken = existingServer.accessToken
            finalUserId = existingServer.userId
        } else if type.isCloudDrive {
            finalAccessToken = currentAccessToken
        }

        server.accessToken = finalAccessToken
        server.userId = finalUserId
        return server
    }

    private func saveServerAndDismiss() {
        let server = createServer()
        if let existingServer {
            if server.accessToken == nil && !type.isCloudDrive {
                networkService.clearServerAuthTokens(for: existingServer.id)
            }
            networkService.updateServer(server)
        } else {
            networkService.addServer(server)
        }
        presentationMode.wrappedValue.dismiss()
    }

    private func startPlexLogin() {
        guard type == .plex else { return }

        plexPollingTask?.cancel()
        plexPin = nil
        isPlexAuthorizing = true
        testResultAlert = nil

        plexPollingTask = Task {
            do {
                let pin = try await PlexPinAuthorizationService.shared.createLoginPin()
                if Task.isCancelled { return }

                await MainActor.run {
                    plexPin = pin
                    isPlexAuthorizing = true
                }

                for _ in 0..<60 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let polled = try await PlexPinAuthorizationService.shared.pollLoginPin(id: pin.id, code: pin.code)
                    guard let token = tvTrimmedText(polled.authToken) else { continue }

                    await MainActor.run {
                        self.currentDraft.accessToken.wrappedValue = token
                        testSucceeded = false
                        testFailed = false
                        isPlexAuthorizing = false
                        plexPin = nil
                        testResultAlert = TVTransientAlert(
                            title: "Plex",
                            message: platformShellString("Token acquired. It will be saved and used automatically.")
                        )
                    }
                    return
                }

                await MainActor.run {
                    isPlexAuthorizing = false
                    plexPin = nil
                    testResultAlert = TVTransientAlert(
                        title: "Plex",
                        message: platformShellString("Plex login timed out. Please try again.")
                    )
                }
            } catch {
                if Task.isCancelled { return }
                let message: String
                if let plexError = error as? PlexPinAuthorizationError {
                    switch plexError {
                    case .invalidResponse:
                        message = platformShellString("Plex server returned an invalid response")
                    }
                } else {
                    message = error.localizedDescription
                }
                await MainActor.run {
                    isPlexAuthorizing = false
                    plexPin = nil
                    testResultAlert = TVTransientAlert(
                        title: platformShellString("Connection Failed"),
                        message: message
                    )
                }
            }
        }
    }

    private func cancelPlexLogin() {
        plexPollingTask?.cancel()
        plexPollingTask = nil
        plexPin = nil
        isPlexAuthorizing = false
    }

    private func testConnection() {
        let server = createServer()
        isTesting = true
        testResultAlert = nil

        testTask = Task {
            do {
                let verifiedServer = try await withThrowingTaskGroup(of: ServerConfig.self) { group in
                    group.addTask {
                        try await tvTestServerConnection(server)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw NSError(
                            domain: "GenPlayerShell",
                            code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection timed out")]
                        )
                    }
                    guard let result = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return result
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    isTesting = false
                    testSucceeded = true
                    testFailed = false
                    testResultAlert = TVTransientAlert(
                        title: platformShellString("Connection Successful"),
                        message: verifiedServer.fullURL
                    )
                    if let token = verifiedServer.accessToken {
                        self.currentDraft.accessToken.wrappedValue = token
                    }
                    verifiedUserId = verifiedServer.userId ?? verifiedUserId
                    self.currentDraft.useSSL.wrappedValue = verifiedServer.useSSL
                    if let port = verifiedServer.port {
                        self.currentDraft.portString.wrappedValue = String(port)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isTesting = false
                    testSucceeded = false
                    testFailed = true
                    self.currentDraft.accessToken.wrappedValue = ""
                    verifiedUserId = nil
                    testResultAlert = TVTransientAlert(
                        title: platformShellString("Connection Failed"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }
}



struct TVServerDiscoveryView: View {
    @ObservedObject private var discoveryService = PlatformServerDiscoveryService.shared
    @ObservedObject private var networkService = AppNetworkService.shared

    var body: some View {
        TVPageScrollView(
            title: platformShellString("Discovered Servers"),
            subtitle: nil,
            handlesExitCommand: true
        ) {
            discoveryStatusPanel

            if !discoveryService.discoveredServers.isEmpty {
                LazyVStack(spacing: 18) {
                    ForEach(discoveryService.discoveredServers) { discoveredServer in
                        let prefilledServer = discoveryService.createServerConfig(from: discoveredServer)
                        NavigationLink(destination: TVServerEditorView(existingServer: nil, prefilledServer: prefilledServer)) {
                            TVDiscoveredServerRow(
                                discoveredServer: discoveredServer,
                                isSaved: isSaved(discoveredServer)
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
            }
        }
        .navigationTitle(Text(platformShellString("Discovered Servers")))
        .onAppear {
            refreshDiscovery()
        }
        .onDisappear {
            discoveryService.stopDiscovery()
        }
    }

    private var discoveryStatusPanel: some View {
        Group {
            if discoveryService.isSearching {
                TVFocusableStaticPanel {
                    TVDiscoveryStatusPanelLabel(
                        title: discoveryStatusTitle,
                        message: discoveryStatusMessage,
                        systemImageName: discoveryStatusIconName,
                        tintColor: discoveryStatusTintColor,
                        isLoading: true,
                        actionTitle: nil
                    )
                }
            } else {
                Button(action: refreshDiscovery) {
                    TVDiscoveryStatusPanelLabel(
                        title: discoveryStatusTitle,
                        message: discoveryStatusMessage,
                        systemImageName: discoveryStatusIconName,
                        tintColor: discoveryStatusTintColor,
                        isLoading: false,
                        actionTitle: platformShellString("Platform Shell TV Discovery Scan Again")
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }

    private var discoveryStatusTitle: String {
        if discoveryService.isSearching {
            return platformShellString("Platform Shell TV Discovery Searching")
        }
        if discoveryService.discoveredServers.isEmpty {
            return platformShellString("Platform Shell TV Empty Discovery Title")
        }
        return platformShellString("Platform Shell TV Discovery Results Title")
    }

    private var discoveryStatusMessage: String {
        if discoveryService.discoveredServers.isEmpty && !discoveryService.isSearching {
            return platformShellString("Platform Shell TV Empty Discovery Body")
        }
        return platformShellString("Platform Shell TV Discover Servers Subtitle")
    }

    private var discoveryStatusIconName: String {
        if discoveryService.isSearching {
            return "dot.radiowaves.left.and.right"
        }
        if discoveryService.discoveredServers.isEmpty {
            return "arrow.clockwise"
        }
        return "checkmark.circle.fill"
    }

    private var discoveryStatusKind: TVFeedbackPanelKind {
        discoveryService.discoveredServers.isEmpty && !discoveryService.isSearching ? .empty : .info
    }

    private var discoveryStatusTintColor: Color {
        discoveryService.isSearching || !discoveryService.discoveredServers.isEmpty
            ? TVShellStyle.accentSoft
            : TVShellStyle.secondary
    }

    private func refreshDiscovery() {
        discoveryService.startDiscovery()
    }

    private func isSaved(_ discoveredServer: PlatformServerDiscoveryService.DiscoveredServer) -> Bool {
        let host = discoveredServer.address.lowercased()
        return networkService.servers.contains { server in
            guard server.type == discoveredServer.type else { return false }
            let serverHost = (URLComponents(string: server.fullURL)?.host ?? server.address)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let serverPort = URLComponents(string: server.fullURL)?.port
                ?? server.port
                ?? ServerConfig.defaultPort(for: server.type, useSSL: server.useSSL)
            return serverHost == host && serverPort == discoveredServer.port
        }
    }
}



struct TVDiscoveryStatusPanelLabel: View {
    let title: String
    let message: String
    let systemImageName: String
    let tintColor: Color
    let isLoading: Bool
    let actionTitle: String?

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var iconColor: Color {
        showsFocus ? primaryColor : tintColor
    }

    private var iconFillColor: Color {
        if showsFocus {
            return Color.black.opacity(colorScheme == .dark ? 0.10 : 0.06)
        }
        return tintColor.opacity(0.14)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(iconFillColor)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.18)
                        .accentColor(iconColor)
                } else {
                    Image(systemName: systemImageName)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(iconColor)
                }
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    if let actionTitle {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .heavy))
                            Text(actionTitle)
                                .font(.system(size: 20, weight: .heavy))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                        .foregroundColor(showsFocus ? primaryColor.opacity(0.78) : tintColor)
                        .padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(message)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tvInteractiveRowPanel()
    }
}



struct TVDiscoveredServerRow: View {
    let discoveredServer: PlatformServerDiscoveryService.DiscoveredServer
    let isSaved: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var metadataLine: String {
        "\(discoveredServer.type.displayName) • \(discoveredServer.address):\(String(discoveredServer.port))"
    }

    var body: some View {
        HStack(spacing: 18) {
            typeIcon(size: 48)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(discoveredServer.name)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(metadataLine)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            Spacer()

            if isSaved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.green)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(secondaryColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .padding(.horizontal, 28)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(showsFocus ? TVRowFocusStyle.focusedFill(for: colorScheme) : TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(showsFocus ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
        )
        .scaleEffect(showsFocus ? 1.010 : 1.0)
        .shadow(
            color: showsFocus ? Color.black.opacity(0.24) : .clear,
            radius: showsFocus ? 16 : 0,
            x: 0,
            y: showsFocus ? 8 : 0
        )
        .animation(.easeOut(duration: 0.14), value: showsFocus)
        .modifier(TVFocusedCardLayerModifier())
    }

    @ViewBuilder
    private func typeIcon(size: CGFloat) -> some View {
        if let uiImage = UIImage(named: discoveredServer.type.iconAssetName) {
            Image(uiImage: uiImage)
                .resizable()
                .renderingMode(showsFocus ? .template : .original)
                .scaledToFit()
                .foregroundColor(primaryColor)
                .frame(width: size, height: size)
        } else {
            Image(systemName: discoveredServer.type.systemIconName)
                .font(.system(size: size * 0.86, weight: .semibold))
                .foregroundColor(showsFocus ? primaryColor : discoveredServer.type.tvAccentColor)
                .frame(width: size, height: size)
        }
    }
}
#endif
