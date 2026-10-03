#if os(macOS)
import SwiftUI
import GenPlayerCore

/// macOS-native Privacy Space unlock sheet.
struct MacPrivacySpaceUnlockView: View {
    @Binding var isPresented: Bool
    var onSuccess: (() -> Void)? = nil

    @ObservedObject private var securityService = SecurityService.shared
    @State private var password = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var errorMessage = ""
    @State private var hasAutoPromptedBiometrics = false

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 76, height: 76)

            VStack(spacing: 8) {
                Text(platformShellString("Privacy Space Locked"))
                    .font(.title2.weight(.semibold))

                Text(platformShellString("Enter your privacy password to unlock protected content."))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                if securityService.isSimplePrivacyPassword {
                    SecureField(platformShellString("Enter 4-digit PIN"), text: $password, onCommit: submitPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16))
                        .frame(width: 280)
                        .offset(x: shakeOffset)
                        .onChange(of: password) { newValue in
                            let digits = newValue.filter(\.isNumber)
                            if digits.count >= 4 {
                                password = String(digits.prefix(4))
                                submitPassword()
                            } else {
                                password = digits
                            }
                        }
                } else {
                    SecureField(platformShellString("Enter Password"), text: $password, onCommit: submitPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16))
                        .frame(width: 280)
                        .offset(x: shakeOffset)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 12) {
                Button(action: { isPresented = false }) {
                    Text(platformShellString("Cancel"))
                        .frame(minWidth: 80)
                }
                .keyboardShortcut(.cancelAction)

                Button(action: submitPassword) {
                    Text(platformShellString("Unlock"))
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)

                if securityService.shouldShowPrivacyBiometricUnlock {
                    Button(action: triggerBiometrics) {
                        Image(systemName: securityService.biometricIconName)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.bordered)
                    .help(securityService.biometricsSettingTitle)
                }
            }
            .frame(width: 280)
        }
        .padding(32)
        .frame(width: 380)
        .onAppear {
            _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
            if securityService.shouldShowPrivacyBiometricUnlock && !hasAutoPromptedBiometrics {
                hasAutoPromptedBiometrics = true
                triggerBiometrics()
            }
        }
    }

    private func submitPassword() {
        guard !password.isEmpty else { return }
        errorMessage = ""
        if securityService.unlockPrivacySpace(with: password) {
            password = ""
            isPresented = false
            onSuccess?()
        } else {
            triggerShake()
        }
    }

    private func triggerBiometrics() {
        let reason = platformShellString("Unlock Privacy Space")
        securityService.authenticateForPrivacy(reason: reason) { success in
            if success {
                DispatchQueue.main.async {
                    isPresented = false
                    onSuccess?()
                }
            }
        }
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
