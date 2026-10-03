import Foundation
#if !os(tvOS)
import LocalAuthentication
#endif
import SwiftUI

public class SecurityService: ObservableObject {
    public enum BiometricType {
        case none
        case faceID
        case touchID

#if !os(tvOS)
        init(_ biometryType: LABiometryType) {
            switch biometryType {
            case .faceID:
                self = .faceID
            case .touchID:
                self = .touchID
            default:
                self = .none
            }
        }
#endif

        var systemImageName: String {
            switch self {
            case .faceID:
                return "faceid"
            case .touchID:
                return "touchid"
            case .none:
                return "faceid"
            }
        }

        var settingsTitle: String {
            switch self {
            case .faceID:
                return NSLocalizedString("Use Face ID", comment: "")
            case .touchID:
                return NSLocalizedString("Use Touch ID", comment: "")
            case .none:
                return NSLocalizedString("Use Face ID/Touch ID", comment: "")
            }
        }
    }

    private struct BiometricEvaluation {
#if !os(tvOS)
        let context: LAContext
#endif
        let canEvaluate: Bool
        let type: BiometricType
#if !os(tvOS)
        let errorCode: LAError.Code?
#endif

        var shouldDisableStoredPreference: Bool {
#if !os(tvOS)
            switch errorCode {
            case .some(.biometryNotAvailable), .some(.biometryNotEnrolled), .some(.passcodeNotSet):
                return true
            default:
                return false
            }
#else
            return false
#endif
        }
    }

    public static let shared = SecurityService()

    @Published public var isLocked: Bool = false {
        didSet {
            if isLocked {
                autoBiometricPrompted = false
            } else {
                isAuthenticating = false
            }
        }
    }

    @Published var isAuthenticating: Bool = false
    var autoBiometricPrompted: Bool = false

    @Published public var isSecurityEnabled: Bool = false
    @Published public var useBiometrics: Bool = false
    @Published public var isPrivacySpaceEnabled: Bool = false
    @Published public var isPrivacySpaceUnlocked: Bool = false {
        didSet {
            if isPrivacySpaceUnlocked {
                isPrivacyAuthenticating = false
            } else {
                showPrivateHistory = false
            }
        }
    }
    @Published public var showPrivateHistory: Bool = false
    @Published var isPrivacyAuthenticating: Bool = false
    @Published public var allowBiometricsForPrivacy: Bool = false
    @Published public var hideLockedItems: Bool = false
    @Published public var excludePrivacyFromHistory: Bool = true
    @Published private(set) var availableBiometricType: BiometricType = .none
    @Published private(set) var isBiometricAvailable: Bool = false
#if !os(tvOS)
    @Published private(set) var biometricErrorCode: LAError.Code?
#endif

    private let securityEnabledKey = "security_enabled"
    private let useBiometricsKey = "use_biometrics"
    private let pinCodeKey = "app_pin_code"
    private let privacySpaceEnabledKey = "privacy_space_enabled"
    private let privacyBiometricsKey = "privacy_space_biometrics"
    private let hideLockedItemsKey = "privacy_space_hide_locked_items"
    private let excludePrivacyFromHistoryKey = "privacy_space_exclude_from_history"
    private let privacyPasswordKey = "privacy_space_password"

    init() {
        self.isSecurityEnabled = UserDefaults.standard.bool(forKey: securityEnabledKey)
        migratePinFromUserDefaultsIfNeeded()

        // Migration: If existing PIN is shorter than 4 digits, disable security and clear PIN
        // to force user to set a valid PIN (min 4 chars) and avoid lockout
        if let storedPin = KeychainService.get(for: pinCodeKey), storedPin.count < 4 {
            KeychainService.delete(for: pinCodeKey)
            UserDefaults.standard.set(false, forKey: securityEnabledKey)
            print("SecurityService: Reset legacy short PIN (<4 chars).")
            self.isSecurityEnabled = false
        }

        self.useBiometrics = UserDefaults.standard.bool(forKey: useBiometricsKey)
        self.isPrivacySpaceEnabled = UserDefaults.standard.bool(forKey: privacySpaceEnabledKey)
        self.allowBiometricsForPrivacy = UserDefaults.standard.bool(forKey: privacyBiometricsKey)
        self.hideLockedItems = UserDefaults.standard.bool(forKey: hideLockedItemsKey)
        self.excludePrivacyFromHistory = boolDefaultingToTrue(forKey: excludePrivacyFromHistoryKey)
        _ = refreshBiometricAvailability(clearUnavailablePreference: true)

        if isSecurityEnabled {
            self.isLocked = true
        }

        if isPrivacySpaceEnabled && !hasPrivacyPassword {
            UserDefaults.standard.set(false, forKey: privacySpaceEnabledKey)
            self.isPrivacySpaceEnabled = false
        }
    }

    private func boolDefaultingToTrue(forKey key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
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

    public var shouldShowBiometricUnlock: Bool {
        useBiometrics && isBiometricAvailable && availableBiometricType != .none
    }

    public var shouldShowPrivacyBiometricUnlock: Bool {
        allowBiometricsForPrivacy && isBiometricAvailable && availableBiometricType != .none
    }

    public var biometricIconName: String {
        availableBiometricType.systemImageName
    }

    public var biometricsSettingTitle: String {
        availableBiometricType.settingsTitle
    }

    public func setPin(_ pin: String) {
        _ = KeychainService.set(pin, for: pinCodeKey)
    }

    public func checkPin(_ pin: String) -> Bool {
        KeychainService.get(for: pinCodeKey) == pin
    }

    public func setPrivacyPassword(_ password: String) {
        _ = KeychainService.set(password, for: privacyPasswordKey)
    }

    public func checkPrivacyPassword(_ password: String) -> Bool {
        KeychainService.get(for: privacyPasswordKey) == password
    }

    public func toggleSecurity(_ enabled: Bool) {
        if enabled && !hasPin {
            return
        }
        isSecurityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: securityEnabledKey)
        if !enabled {
            isLocked = false
        }
    }

    public func togglePrivacySpace(_ enabled: Bool) {
        if enabled && !hasPrivacyPassword {
            return
        }

        isPrivacySpaceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: privacySpaceEnabledKey)

        if !enabled {
            isPrivacySpaceUnlocked = false
        }
    }

    @discardableResult
    public func toggleBiometrics(_ enabled: Bool) -> Bool {
        if enabled {
            let evaluation = evaluateBiometrics()
            applyBiometricEvaluation(evaluation)
            guard evaluation.canEvaluate else {
                return false
            }
        } else {
            autoBiometricPrompted = false
        }

        persistBiometricsPreference(enabled)
        return true
    }

    @discardableResult
    public func authenticate(reason: String = NSLocalizedString("Unlock App", comment: ""), completion: ((Bool) -> Void)? = nil) {
        guard isSecurityEnabled, useBiometrics else {
            completion?(true)
            return
        }

#if !os(tvOS)
        let evaluation = evaluateBiometrics()
        guard evaluation.canEvaluate else {
            completion?(false)
            return
        }

        evaluation.context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                if success {
                    self.isLocked = false
                }
                completion?(success)
            }
        }
#else
        completion?(false)
#endif
    }

    @discardableResult
    public func togglePrivacyBiometrics(_ enabled: Bool) -> Bool {
        if enabled {
            let evaluation = evaluateBiometrics()
            applyBiometricEvaluation(evaluation)
            guard evaluation.canEvaluate else {
                return false
            }
        }

        persistPrivacyBiometricsPreference(enabled)
        return true
    }

    public func unlock(with pin: String) -> Bool {
        if checkPin(pin) {
            isLocked = false
            return true
        }
        return false
    }

    public func unlockPrivacySpace(with password: String) -> Bool {
        guard isPrivacySpaceEnabled else { return false }
        if checkPrivacyPassword(password) {
            isPrivacySpaceUnlocked = true
            return true
        }
        return false
    }

    public func authenticateForPrivacy(reason: String = NSLocalizedString("Unlock Privacy Space", comment: ""), completion: ((Bool) -> Void)? = nil) {
        guard isPrivacySpaceEnabled, allowBiometricsForPrivacy else {
            completion?(true)
            return
        }

#if !os(tvOS)
        let evaluation = evaluateBiometrics()
        guard evaluation.canEvaluate else {
            completion?(false)
            return
        }

        evaluation.context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                if success {
                    self.isPrivacySpaceUnlocked = true
                }
                completion?(success)
            }
        }
#else
        completion?(false)
#endif
    }

    public func autoAuthenticateIfNeeded() {
        guard isSecurityEnabled && useBiometrics && isLocked else { return }
        guard !autoBiometricPrompted else { return }
        guard refreshBiometricAvailability(clearUnavailablePreference: true) else { return }

        autoBiometricPrompted = true
        authenticate()
    }

    public func attemptAutoUnlock(completion: ((Bool) -> Void)? = nil) {
        guard isLocked, useBiometrics, !autoBiometricPrompted else {
            completion?(false)
            return
        }

#if !os(tvOS)
        let evaluation = evaluateBiometrics()
        guard evaluation.canEvaluate else {
            completion?(false)
            return
        }

        autoBiometricPrompted = true
        isAuthenticating = true

        evaluation.context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: NSLocalizedString("Unlock App", comment: "")) { success, _ in
            DispatchQueue.main.async {
                self.isAuthenticating = false
                if success {
                    self.isLocked = false
                }
                completion?(success)
            }
        }
#else
        completion?(false)
#endif
    }

    @discardableResult
    public func refreshBiometricAvailability(clearUnavailablePreference: Bool = false) -> Bool {
        let evaluation = evaluateBiometrics()
        applyBiometricEvaluation(evaluation)

        if clearUnavailablePreference && useBiometrics && evaluation.shouldDisableStoredPreference {
            persistBiometricsPreference(false)
        }

        return evaluation.canEvaluate
    }

    public func lockPrivacySpace() {
        guard isPrivacySpaceEnabled else { return }
        isPrivacySpaceUnlocked = false
        isPrivacyAuthenticating = false
    }

    public func biometricsUnavailableMessage() -> String {
#if !os(tvOS)
        switch biometricErrorCode {
        case .some(.biometryNotEnrolled):
            return NSLocalizedString("Biometric unlock is not configured on this device. Set up Face ID or Touch ID in the system Settings first.", comment: "")
        case .some(.biometryNotAvailable):
            return NSLocalizedString("This device does not support biometric unlock.", comment: "")
        case .some(.passcodeNotSet):
            return NSLocalizedString("A device passcode is required before Face ID or Touch ID can be used.", comment: "")
        case .some(.biometryLockout):
            return NSLocalizedString("Biometric unlock is temporarily unavailable. Unlock the device once at the system level and try again.", comment: "")
        default:
            return NSLocalizedString("Biometric unlock is currently unavailable on this device.", comment: "")
        }
#else
        return NSLocalizedString("Biometric unlock is currently unavailable on this device.", comment: "")
#endif
    }

    private func migratePinFromUserDefaultsIfNeeded() {
        guard KeychainService.get(for: pinCodeKey) == nil,
              let legacyPin = UserDefaults.standard.string(forKey: pinCodeKey) else { return }

        if KeychainService.set(legacyPin, for: pinCodeKey) {
            UserDefaults.standard.removeObject(forKey: pinCodeKey)
            print("SecurityService: Migrated PIN from UserDefaults to Keychain.")
        }
    }

    private func persistBiometricsPreference(_ enabled: Bool) {
        useBiometrics = enabled
        UserDefaults.standard.set(enabled, forKey: useBiometricsKey)
    }

    private func persistPrivacyBiometricsPreference(_ enabled: Bool) {
        allowBiometricsForPrivacy = enabled
        UserDefaults.standard.set(enabled, forKey: privacyBiometricsKey)
    }

    public func setHideLockedItems(_ enabled: Bool) {
        hideLockedItems = enabled
        UserDefaults.standard.set(enabled, forKey: hideLockedItemsKey)
    }

    public func setExcludePrivacyFromHistory(_ enabled: Bool) {
        excludePrivacyFromHistory = enabled
        UserDefaults.standard.set(enabled, forKey: excludePrivacyFromHistoryKey)
    }

    private func evaluateBiometrics() -> BiometricEvaluation {
#if !os(tvOS)
        let context = LAContext()
        context.localizedFallbackTitle = ""

        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let errorCode = error.flatMap { LAError.Code(rawValue: $0.code) }

        return BiometricEvaluation(
            context: context,
            canEvaluate: canEvaluate,
            type: BiometricType(context.biometryType),
            errorCode: errorCode
        )
#else
        return BiometricEvaluation(canEvaluate: false, type: .none)
#endif
    }

    private func applyBiometricEvaluation(_ evaluation: BiometricEvaluation) {
        let update = {
            self.availableBiometricType = evaluation.type
            self.isBiometricAvailable = evaluation.canEvaluate
#if !os(tvOS)
            self.biometricErrorCode = evaluation.errorCode
#endif
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}
