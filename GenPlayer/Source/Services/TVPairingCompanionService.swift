#if os(iOS)
import UIKit
import Foundation
import AuthenticationServices
import GenPlayerCore

public struct TVPairingSession: Identifiable, Equatable {
    public let id = UUID()
    public let ip: String
    public let port: Int
    public let secret: String
    public let serverType: ServerConfig.ServerType

    public static func == (lhs: TVPairingSession, rhs: TVPairingSession) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
public final class TVPairingCompanionService: NSObject, ObservableObject {
    public static let shared = TVPairingCompanionService()

    @Published public var activeSession: TVPairingSession?
    @Published public var isAuthenticating = false
    @Published public var statusMessage = ""
    @Published public var isSuccess = false
    @Published public var errorMessage: String?

    private var currentAuthSession: ASWebAuthenticationSession?
    private var authorizationTask: Task<Void, Never>?
    private var attemptID: UUID?
    private let pairingTransport = URLSession(configuration: .ephemeral, delegate: TVPairingRedirectGuard(), delegateQueue: nil)

    @discardableResult
    public static func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "genplayer", url.host?.lowercased() == "pair",
              case let .pairing(pairing) = TVAuthorizationQRCode.parse(url.absoluteString) else { return false }
        shared.presentPairing(pairing)
        return true
    }

    func presentPairing(_ pairing: TVAuthorizationQRCode.Pairing) {
        // Duplicate deep-link delivery must not replace an authorization already on screen.
        guard activeSession == nil,
              let type = ServerConfig.ServerType(rawValue: pairing.provider) else { return }
        dismissSession()
        activeSession = TVPairingSession(ip: pairing.ip, port: pairing.port, secret: pairing.secret, serverType: type)
    }

    public func dismissSession() {
        attemptID = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        currentAuthSession?.cancel()
        currentAuthSession = nil
        activeSession = nil
        isAuthenticating = false
        statusMessage = ""
        isSuccess = false
        errorMessage = nil
    }

    public func startDirectOAuthLogin(for session: TVPairingSession) {
        guard activeSession?.id == session.id, !isAuthenticating, !isSuccess else { return }
        let isGoogle = session.serverType == .googledrive
        guard isGoogle || session.serverType == .onedrive else { return }

        let attempt = UUID()
        attemptID = attempt
        isAuthenticating = true
        errorMessage = nil
        statusMessage = NSLocalizedString("Waiting for login...", comment: "")

        // PKCE generation is identical for both providers; credentials belong only to this attempt.
        let pkce = GoogleDriveManager.generatePKCE()
        let state = UUID().uuidString
        let authURL = isGoogle
            ? GoogleDriveManager.buildAuthorizationURL(challenge: pkce.challenge, state: state)
            : OneDriveManager.buildAuthorizationURL(challenge: pkce.challenge, state: state)
        guard let authURL else {
            fail(NSLocalizedString("Unable to start authorization. Please try again.", comment: ""), attempt: attempt)
            return
        }
        let callbackScheme = isGoogle ? GoogleDriveManager.callbackScheme : "genplayer"
        let webAuth = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(session, attempt: attempt) else { return }
                self.currentAuthSession = nil
                if let error {
                    self.isAuthenticating = false
                    if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      components.scheme == callbackScheme,
                      isGoogle || (components.host == "oauth" && components.path == "/onedrive"),
                      components.queryItems?.filter({ $0.name == "state" }).count == 1,
                      components.queryItems?.first(where: { $0.name == "state" })?.value == state,
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    self.fail(NSLocalizedString("Authorization code not returned.", comment: ""), attempt: attempt)
                    return
                }
                self.statusMessage = NSLocalizedString("Exchanging token...", comment: "")
                self.authorizationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let accessToken: String
                        let refreshToken: String
                        let displayName: String
                        if isGoogle {
                            let tokens = try await GoogleDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
                            accessToken = tokens.accessToken
                            refreshToken = tokens.refreshToken
                            displayName = tokens.displayName
                        } else {
                            let tokens = try await OneDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
                            accessToken = tokens.accessToken
                            refreshToken = tokens.refreshToken
                            displayName = tokens.displayName
                        }
                        guard self.isCurrent(session, attempt: attempt), !Task.isCancelled else { return }
                        await self.sendPairingPayload(session: session, attempt: attempt,
                            accessToken: accessToken, refreshToken: refreshToken,
                            displayName: displayName.isEmpty ? session.serverType.displayName : displayName)
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.fail(error.localizedDescription, attempt: attempt)
                    }
                }
            }
        }
        webAuth.presentationContextProvider = self
        webAuth.prefersEphemeralWebBrowserSession = false
        currentAuthSession = webAuth
        if !webAuth.start() {
            currentAuthSession = nil
            fail(NSLocalizedString("Unable to start authorization. Please try again.", comment: ""), attempt: attempt)
        }
    }

    private func isCurrent(_ session: TVPairingSession, attempt: UUID) -> Bool {
        activeSession?.id == session.id && attemptID == attempt
    }

    private func fail(_ message: String, attempt: UUID) {
        guard attemptID == attempt else { return }
        isAuthenticating = false
        errorMessage = message
    }

    private func sendPairingPayload(session: TVPairingSession, attempt: UUID,
                                    accessToken: String, refreshToken: String, displayName: String) async {
        guard isCurrent(session, attempt: attempt), !Task.isCancelled,
              let url = URL(string: "http://\(session.ip):\(session.port)/api/pair") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        statusMessage = NSLocalizedString("Connecting to Apple TV...", comment: "")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "secret": session.secret, "type": session.serverType.rawValue,
                "accessToken": accessToken, "refreshToken": refreshToken, "displayName": displayName
            ])
            let (_, response) = try await pairingTransport.data(for: request)
            guard isCurrent(session, attempt: attempt), !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                fail(NSLocalizedString("TV authorization failed. Please scan the current QR code on your TV again.", comment: ""), attempt: attempt)
                return
            }
            isAuthenticating = false
            isSuccess = true
            statusMessage = NSLocalizedString("Successfully authorized Apple TV!", comment: "")
            try await Task.sleep(nanoseconds: 1_200_000_000)
            guard isCurrent(session, attempt: attempt), !Task.isCancelled else { return }
            dismissSession()
        } catch {
            guard !Task.isCancelled else { return }
            fail(NSLocalizedString("Could not connect to Apple TV. Please ensure both devices are on the same Wi-Fi network.", comment: ""), attempt: attempt)
        }
    }
}

extension TVPairingCompanionService: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first(where: { !$0.isHidden }) else {
            return ASPresentationAnchor()
        }
        return window
    }
}

/// Never redirect a request containing credentials to another endpoint.
private final class TVPairingRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
