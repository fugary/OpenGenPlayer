#if os(macOS)
import SwiftUI
import GenPlayerCore

struct MacLockScreenView: View {
    @ObservedObject var securityService: SecurityService
    @State private var password = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var errorMessage = ""
    @State private var hasAutoPromptedBiometrics = false

    var body: some View {
        ZStack {
            // macOS native glass backdrop
            Color(NSColor.windowBackgroundColor).opacity(0.3)
                .background(Material.thin)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Lock Icon
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 80, height: 80)

                VStack(spacing: 8) {
                    Text(platformShellString("App Locked"))
                        .font(.title.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(platformShellString("Enter your PIN to unlock the app."))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField(platformShellString("Enter App PIN"), text: $password, onCommit: verifyPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 16))
                            .frame(width: 280)
                            .offset(x: shakeOffset)
                            .onChange(of: password) { newValue in
                                if securityService.isSimplePin && newValue.count == 4 {
                                    verifyPassword()
                                }
                            }

                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                                .transition(.opacity)
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: verifyPassword) {
                            Text(platformShellString("Unlock"))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        
                        if securityService.shouldShowBiometricUnlock {
                            Button(action: triggerBiometrics) {
                                Image(systemName: securityService.biometricIconName)
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .help(securityService.biometricsSettingTitle)
                        }
                    }
                    .frame(width: 280)
                }
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.8))
            )
            .background(
                Color(NSColor.windowBackgroundColor).opacity(0.5)
                    .background(Material.regular)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
        }
        .onAppear {
            _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
            if securityService.shouldShowBiometricUnlock && !hasAutoPromptedBiometrics {
                hasAutoPromptedBiometrics = true
                triggerBiometrics()
            }
        }
    }

    private func verifyPassword() {
        guard !password.isEmpty else { return }
        errorMessage = ""
        if securityService.unlock(with: password) {
            password = ""
        } else {
            triggerShake()
        }
    }

    private func triggerBiometrics() {
        securityService.authenticate()
    }

    private func triggerShake() {
        errorMessage = platformShellString("Incorrect password. Try again.")
        withAnimation(.interactiveSpring(response: 0.1, dampingFraction: 0.3, blendDuration: 0.1)) {
            shakeOffset = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.interactiveSpring(response: 0.1, dampingFraction: 0.3, blendDuration: 0.1)) {
                shakeOffset = -10
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.5, blendDuration: 0.1)) {
                shakeOffset = 0
                password = ""
            }
        }
    }
}
#endif
