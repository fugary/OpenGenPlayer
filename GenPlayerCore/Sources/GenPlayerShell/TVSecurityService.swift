import GenPlayerCore

#if os(tvOS)
import Combine
import Foundation
import SwiftUI
import UIKit

public final class TVSecurityService: ObservableObject {
    public static let shared = TVSecurityService()

    @Published public private(set) var isSecurityEnabled: Bool
    @Published public var isLocked: Bool
    @Published public private(set) var isPrivacySpaceEnabled: Bool
    @Published public var isPrivacySpaceUnlocked: Bool
    @Published public var showPrivateHistory: Bool = false
    @Published public private(set) var hideLockedItems: Bool
    @Published public private(set) var excludePrivacyFromHistory: Bool

    private let securityEnabledKey = "security_enabled"
    private let pinCodeKey = "app_pin_code"
    private let privacySpaceEnabledKey = "privacy_space_enabled"
    private let hideLockedItemsKey = "privacy_space_hide_locked_items"
    private let excludePrivacyFromHistoryKey = "privacy_space_exclude_from_history"
    private let excludePrivacyFromHistoryDefaultV2Key = "privacy_space_exclude_from_history_default_v2_applied"
    private let privacyPasswordKey = "privacy_space_password"

    private init() {
        let defaults = UserDefaults.standard
        let securityEnabled = defaults.bool(forKey: securityEnabledKey)
        let privacySpaceEnabled = defaults.bool(forKey: privacySpaceEnabledKey)
        isSecurityEnabled = securityEnabled
        isPrivacySpaceEnabled = privacySpaceEnabled
        hideLockedItems = defaults.bool(forKey: hideLockedItemsKey)
        excludePrivacyFromHistory = Self.boolDefaultingToTrue(
            forKey: excludePrivacyFromHistoryKey,
            defaults: defaults
        )
        isLocked = securityEnabled
        isPrivacySpaceUnlocked = false

        migratePinFromUserDefaultsIfNeeded()
        resetInvalidLegacyPinIfNeeded()
        restoreDurablePreferences(defaults: defaults)
        resetInvalidPrivacySpaceIfNeeded()
    }

    public var hasPin: Bool {
        KeychainService.get(for: pinCodeKey) != nil
    }

    public var isSimplePin: Bool {
        guard let pin = KeychainService.get(for: pinCodeKey) else { return false }
        return pin.allSatisfy { $0.isNumber } && pin.count == 4
    }

    public var hasPrivacyPassword: Bool {
        KeychainService.get(for: privacyPasswordKey) != nil
    }

    public var isSimplePrivacyPassword: Bool {
        guard let password = KeychainService.get(for: privacyPasswordKey) else { return false }
        return password.allSatisfy { $0.isNumber } && password.count == 4
    }

    public func setPin(_ pin: String) {
        _ = KeychainService.set(pin, for: pinCodeKey)
    }

    public func checkPin(_ pin: String) -> Bool {
        KeychainService.get(for: pinCodeKey) == pin
    }

    public func toggleSecurity(_ enabled: Bool) {
        guard !enabled || hasPin else { return }
        isSecurityEnabled = enabled
        persistDurableBool(enabled, forKey: securityEnabledKey)
        if !enabled {
            isLocked = false
        }
    }

    public func lock() {
        guard isSecurityEnabled else { return }
        isLocked = true
    }

    @discardableResult
    public func unlock(with pin: String) -> Bool {
        guard isSecurityEnabled else { return false }
        guard checkPin(pin) else { return false }
        isLocked = false
        return true
    }

    public func setPrivacyPassword(_ password: String) {
        _ = KeychainService.set(password, for: privacyPasswordKey)
    }

    public func checkPrivacyPassword(_ password: String) -> Bool {
        KeychainService.get(for: privacyPasswordKey) == password
    }

    public func togglePrivacySpace(_ enabled: Bool) {
        guard !enabled || hasPrivacyPassword else { return }
        isPrivacySpaceEnabled = enabled
        persistDurableBool(enabled, forKey: privacySpaceEnabledKey)
        if !enabled {
            isPrivacySpaceUnlocked = false
        }
    }

    public func lockPrivacySpace() {
        guard isPrivacySpaceEnabled else { return }
        isPrivacySpaceUnlocked = false
        showPrivateHistory = false
    }

    @discardableResult
    public func unlockPrivacySpace(with password: String) -> Bool {
        guard isPrivacySpaceEnabled else { return false }
        guard checkPrivacyPassword(password) else { return false }
        isPrivacySpaceUnlocked = true
        return true
    }

    public func setHideLockedItems(_ enabled: Bool) {
        hideLockedItems = enabled
        persistDurableBool(enabled, forKey: hideLockedItemsKey)
    }

    public func setExcludePrivacyFromHistory(_ enabled: Bool) {
        excludePrivacyFromHistory = enabled
        persistDurableBool(enabled, forKey: excludePrivacyFromHistoryKey)
        UserDefaults.standard.set(true, forKey: excludePrivacyFromHistoryDefaultV2Key)
    }

    private func migratePinFromUserDefaultsIfNeeded() {
        guard KeychainService.get(for: pinCodeKey) == nil,
              let legacyPin = UserDefaults.standard.string(forKey: pinCodeKey) else { return }

        if KeychainService.set(legacyPin, for: pinCodeKey) {
            UserDefaults.standard.removeObject(forKey: pinCodeKey)
        }
    }

    private func resetInvalidLegacyPinIfNeeded() {
        guard let storedPin = KeychainService.get(for: pinCodeKey), storedPin.count < 4 else { return }
        KeychainService.delete(for: pinCodeKey)
        persistDurableBool(false, forKey: securityEnabledKey)
        isSecurityEnabled = false
        isLocked = false
    }

    private func resetInvalidPrivacySpaceIfNeeded() {
        guard isPrivacySpaceEnabled && !hasPrivacyPassword else { return }
        persistDurableBool(false, forKey: privacySpaceEnabledKey)
        isPrivacySpaceEnabled = false
        isPrivacySpaceUnlocked = false
    }

    private func restoreDurablePreferences(defaults: UserDefaults) {
        let appLockDefault = defaults.object(forKey: securityEnabledKey) == nil && hasPin
        let privacyDefault = defaults.object(forKey: privacySpaceEnabledKey) == nil && hasPrivacyPassword

        isSecurityEnabled = resolvedDurableBool(
            forKey: securityEnabledKey,
            defaults: defaults,
            defaultValue: appLockDefault
        ) && hasPin
        isPrivacySpaceEnabled = resolvedDurableBool(
            forKey: privacySpaceEnabledKey,
            defaults: defaults,
            defaultValue: privacyDefault
        ) && hasPrivacyPassword
        hideLockedItems = resolvedDurableBool(
            forKey: hideLockedItemsKey,
            defaults: defaults,
            defaultValue: false
        )
        let hasAppliedExcludeDefaultV2 = defaults.bool(forKey: excludePrivacyFromHistoryDefaultV2Key)
        let resolvedExcludePrivacyFromHistory = resolvedDurableBool(
            forKey: excludePrivacyFromHistoryKey,
            defaults: defaults,
            defaultValue: true
        )
        excludePrivacyFromHistory = hasAppliedExcludeDefaultV2
            ? resolvedExcludePrivacyFromHistory
            : true
        isLocked = isSecurityEnabled
        isPrivacySpaceUnlocked = false

        persistDurableBool(isSecurityEnabled, forKey: securityEnabledKey)
        persistDurableBool(isPrivacySpaceEnabled, forKey: privacySpaceEnabledKey)
        persistDurableBool(hideLockedItems, forKey: hideLockedItemsKey)
        persistDurableBool(excludePrivacyFromHistory, forKey: excludePrivacyFromHistoryKey)
        defaults.set(true, forKey: excludePrivacyFromHistoryDefaultV2Key)
    }

    private func resolvedDurableBool(
        forKey key: String,
        defaults: UserDefaults,
        defaultValue: Bool
    ) -> Bool {
        if let keychainValue = KeychainService.get(for: key),
           let boolValue = Self.boolValue(from: keychainValue) {
            return boolValue
        }

        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }

        return defaultValue
    }

    private func persistDurableBool(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        _ = KeychainService.set(value ? "true" : "false", for: key)
    }

    private static func boolValue(from string: String) -> Bool? {
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    private static func boolDefaultingToTrue(
        forKey key: String,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

public struct TVAppUnlockView: View {
    @ObservedObject private var securityService = TVSecurityService.shared
    @State private var password = ""
    @State private var errorMessage = ""

    public init() {}

    public var body: some View {
        TVSecurityBackdrop {
            VStack(spacing: 30) {
                TVSecurityHeroIcon(systemImageName: "lock.fill")

                VStack(spacing: 10) {
                    Text(platformShellString("App Lock"))
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(platformShellString("Enter your password to open Gen Player on this Apple TV."))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white.opacity(0.70))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                TVSecurityPasswordField(
                    placeholder: securityService.isSimplePin
                        ? platformShellString("Enter 4-digit PIN")
                        : platformShellString("Enter Password"),
                    isSimple: securityService.isSimplePin,
                    text: $password,
                    onSubmit: submitPassword
                )

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(Color(red: 1.0, green: 0.34, blue: 0.30))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                Button(action: submitPassword) {
                    TVSecurityPanelActionLabel(
                        title: platformShellString("Unlock"),
                        systemImageName: "lock.open",
                        isPrimary: true
                    )
                }
                .buttonStyle(TVSecurityButtonStyle())
                .tvDisableSystemFocusEffect()
                .disabled(password.isEmpty)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 58)
            .frame(width: 760)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(Color.black.opacity(0.48))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 34, x: 0, y: 22)
        }
    }

    private func submitPassword() {
        errorMessage = ""
        guard securityService.unlock(with: password) else {
            errorMessage = platformShellString("Incorrect password. Try again.")
            password = ""
            return
        }
    }
}

struct TVPrivacyProtectedContent<Content: View>: View {
    let title: String
    let isProtected: Bool
    let content: () -> Content

    @ObservedObject private var securityService = TVSecurityService.shared

    init(title: String, isProtected: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isProtected = isProtected
        self.content = content
    }

    private var computedProtected: Bool {
        isProtected && securityService.isPrivacySpaceEnabled && !securityService.isPrivacySpaceUnlocked
    }

    var body: some View {
        if computedProtected {
            TVPrivacyUnlockGate(title: title)
        } else {
            content()
        }
    }
}

struct TVPrivacyUnlockGate: View {
    let title: String
    @Environment(\.tvBrowsingNavigation) private var browsingNavigation
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var securityService = TVSecurityService.shared
    @State private var password = ""
    @State private var errorMessage = ""

    var body: some View {
        TVSecurityBackdrop {
            TVPrivacyUnlockPanel(
                title: platformShellString("Privacy Space Locked"),
                message: String(
                    format: platformShellString("Unlock Privacy Space to access \"%@\" and all protected content."),
                    title
                ),
                passwordTitle: platformShellString("Privacy Password"),
                placeholder: securityService.isSimplePrivacyPassword
                    ? platformShellString("Enter 4-digit PIN")
                    : platformShellString("Enter Password"),
                isSimplePassword: securityService.isSimplePrivacyPassword,
                password: $password,
                errorMessage: errorMessage,
                primaryTitle: platformShellString("Unlock Privacy Space"),
                primarySystemImageName: "lock.open",
                onSubmit: submitPassword
            )
        }
        .onExitCommand {
            if let browsingNavigation {
                browsingNavigation.back()
            } else {
                dismiss()
            }
        }
    }

    private func submitPassword() {
        errorMessage = ""
        guard securityService.unlockPrivacySpace(with: password) else {
            errorMessage = platformShellString("Incorrect privacy password. Try again.")
            password = ""
            return
        }
    }
}

func tvRequiresPrivacyAccess(server: ServerConfig) -> Bool {
    let securityService = TVSecurityService.shared
    return securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        PrivacySpaceService.shared.isServerMarkedPrivate(server)
}

func tvRequiresPrivacyAccess(file: VideoFile) -> Bool {
    let securityService = TVSecurityService.shared
    return securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        PrivacySpaceService.shared.isFileMarkedPrivate(file)
}

func tvRequiresPrivacyAccess(server: ServerConfig, remotePath: String) -> Bool {
    let securityService = TVSecurityService.shared
    let privacySpaceService = PrivacySpaceService.shared
    return securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        (
            privacySpaceService.isServerMarkedPrivate(server) ||
            privacySpaceService.isRemoteFolderMarkedPrivate(server: server, path: remotePath)
        )
}

func tvShouldHidePrivateServer(_ server: ServerConfig, includeServerListPreference: Bool = false) -> Bool {
    let securityService = TVSecurityService.shared
    guard securityService.isPrivacySpaceEnabled,
          !securityService.isPrivacySpaceUnlocked,
          securityService.hideLockedItems || includeServerListPreference else {
        return false
    }
    return PrivacySpaceService.shared.isServerMarkedPrivate(server)
}

func tvShouldHidePrivateFile(_ file: VideoFile) -> Bool {
    let securityService = TVSecurityService.shared
    guard securityService.isPrivacySpaceEnabled,
          !securityService.isPrivacySpaceUnlocked,
          securityService.hideLockedItems else {
        return false
    }
    return PrivacySpaceService.shared.isFileMarkedPrivate(file)
}

func tvShouldHidePrivateFavorite(_ item: FavoriteItem) -> Bool {
    let securityService = TVSecurityService.shared
    guard securityService.isPrivacySpaceEnabled,
          !securityService.isPrivacySpaceUnlocked,
          securityService.hideLockedItems else {
        return false
    }
    return PrivacySpaceService.shared.isFavoriteMarkedPrivate(item)
}

struct TVSecurityBackdrop<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.018, green: 0.020, blue: 0.028),
                    Color(red: 0.035, green: 0.070, blue: 0.105),
                    Color(red: 0.008, green: 0.010, blue: 0.016)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.12, green: 0.52, blue: 0.78).opacity(0.18),
                    Color.clear,
                    Color.black.opacity(0.44)
                ]),
                startPoint: .topLeading,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            content()
        }
    }
}

struct TVPrivacyUnlockPanel: View {
    let title: String
    let message: String
    let passwordTitle: String
    let placeholder: String
    let isSimplePassword: Bool
    @Binding var password: String
    let errorMessage: String
    let primaryTitle: String
    let primarySystemImageName: String
    var cancelTitle: String? = nil
    let onSubmit: () -> Void
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 30) {
            TVSecurityHeroIcon(systemImageName: "lock.fill")

            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 54, weight: .heavy))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(message)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white.opacity(0.70))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TVSecurityPasswordField(
                placeholder: placeholder,
                isSimple: isSimplePassword,
                text: $password,
                onSubmit: onSubmit
            )

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.36, blue: 0.32))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 18) {
                Button(action: onSubmit) {
                    TVSecurityPanelActionLabel(
                        title: primaryTitle,
                        systemImageName: primarySystemImageName,
                        isPrimary: true
                    )
                }
                .buttonStyle(TVSecurityButtonStyle())
                .tvDisableSystemFocusEffect()
                .disabled(password.isEmpty)

                if let cancelTitle, let onCancel {
                    Button(action: onCancel) {
                        TVSecurityPanelActionLabel(
                            title: cancelTitle,
                            systemImageName: "xmark",
                            isPrimary: false
                        )
                    }
                    .buttonStyle(TVSecurityButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .tvFocusSectionIfAvailable()
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 58)
        .frame(width: 760)
        .background(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color.black.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 34, x: 0, y: 22)
    }
}

private struct TVSecurityHeroIcon: View {
    let systemImageName: String

    var body: some View {
        Image(systemName: systemImageName)
            .font(.system(size: 31, weight: .heavy))
            .foregroundColor(.white)
            .frame(width: 74, height: 74)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.58, blue: 0.86).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.16, green: 0.58, blue: 0.86).opacity(0.26), radius: 14, x: 0, y: 8)
    }
}

private struct TVSecurityPasswordField: View {
    let placeholder: String
    let isSimple: Bool
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TVSecurePasswordTextField(
            placeholder: placeholder,
            isSimple: isSimple,
            text: $text,
            onSubmit: onSubmit
        )
            .frame(height: 74)
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .tvDisableSystemFocusEffect()
    }
}

private struct TVSecurePasswordTextField: UIViewRepresentable {
    let placeholder: String
    let isSimple: Bool
    @Binding var text: String
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let textField = TVInsetSecureTextField(frame: .zero)
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.background = nil
        textField.disabledBackground = nil
        textField.textColor = UIColor.white.withAlphaComponent(0.96)
        textField.tintColor = UIColor(red: 0.34, green: 0.78, blue: 1.0, alpha: 1.0)
        textField.font = UIFont.systemFont(ofSize: 30, weight: .semibold)
        textField.isSecureTextEntry = true
        textField.textContentType = .password
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .done
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        uiView.keyboardType = isSimple ? .numberPad : .default
        uiView.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: UIColor.white.withAlphaComponent(0.38)
            ]
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func normalizedText(_ rawValue: String) -> String {
        guard isSimple else { return rawValue }
        return String(rawValue.filter { "0123456789".contains($0) }.prefix(4))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TVSecurePasswordTextField

        init(parent: TVSecurePasswordTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let rawValue = textField.text ?? ""
            let normalized = parent.normalizedText(rawValue)
            let shouldSubmit = parent.isSimple && normalized.count == 4 && parent.text != normalized

            if normalized != rawValue {
                textField.text = normalized
            }

            if parent.text != normalized {
                parent.text = normalized
            }

            if shouldSubmit {
                parent.onSubmit()
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}

private final class TVInsetSecureTextField: UITextField {
    private let horizontalInset: CGFloat = 32

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: horizontalInset, dy: 0)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: horizontalInset, dy: 0)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: horizontalInset, dy: 0)
    }
}

private struct TVSecurityPanelActionLabel: View {
    let title: String
    let systemImageName: String
    let isPrimary: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var fillColor: Color {
        if isFocused {
            return .white.opacity(0.94)
        }
        if isPrimary {
            return Color(red: 0.16, green: 0.58, blue: 0.86).opacity(isEnabled ? 0.95 : 0.34)
        }
        return Color.white.opacity(isEnabled ? 0.12 : 0.06)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .white.opacity(0.42) }
        if isFocused {
            return .black.opacity(0.88)
        }
        return .white.opacity(isPrimary ? 0.96 : 0.82)
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImageName)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 24, height: 24)
            Text(title)
                .font(.system(size: 23, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 28)
        .frame(minWidth: isPrimary ? 260 : 160)
        .frame(height: 58)
        .background(
            Capsule(style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isFocused ? Color.clear : Color.white.opacity(0.14), lineWidth: 1)
        )
        .scaleEffect(isFocused ? 1.035 : 1.0)
        .shadow(color: isFocused ? Color.black.opacity(0.24) : .clear, radius: 14, x: 0, y: 7)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .animation(.easeOut(duration: 0.16), value: isEnabled)
    }
}

private struct TVSecurityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
#endif

func tvShouldExcludePrivateHistory(for file: VideoFile) -> Bool {
    #if os(tvOS)
    let securityService = TVSecurityService.shared
    return securityService.isPrivacySpaceEnabled &&
        securityService.excludePrivacyFromHistory &&
        PrivacySpaceService.shared.isFileMarkedPrivate(file)
    #else
    return false
    #endif
}

func tvShouldHidePrivateHistoryItem(_ file: VideoFile) -> Bool {
    #if os(tvOS)
    let securityService = TVSecurityService.shared
    guard securityService.isPrivacySpaceEnabled else { return false }
    guard PrivacySpaceService.shared.isFileMarkedPrivate(file) else { return false }
    if !securityService.isPrivacySpaceUnlocked {
        return true
    }
    if securityService.excludePrivacyFromHistory {
        return !securityService.showPrivateHistory
    }
    return false
    #else
    return false
    #endif
}
