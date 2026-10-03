#if os(iOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LockScreenView: View {
    @ObservedObject var securityService: SecurityService
    @State private var pin: String = ""
    @State private var shakeDegrees: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LockScreenBackdrop()

                let isLandscape = geo.size.width > geo.size.height
                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                Group {
                    if securityService.isSimplePin {
                        simplePinLayout(in: geo, isLandscape: isLandscape, isPad: isPad)
                    } else {
                        VStack(spacing: 30) {
                            Spacer()

                            VStack(spacing: 24) {
                                LockTitleView(
                                    iconSize: 100,
                                    titleFont: .title2,
                                    titleLineLimit: 2
                                )

                                VStack(spacing: 18) {
                                    SecureField(NSLocalizedString("Enter Password", comment: ""), text: $pin)
                                        .padding(.horizontal, 18)
                                        .frame(height: 56)
                                        .background(LockFieldBackground())
                                        .foregroundColor(.white)
                                        .accentColor(.white)
                                        .frame(maxWidth: 300)
                                        .offset(x: shakeDegrees)

                                    HStack(spacing: 16) {
                                        if securityService.shouldShowBiometricUnlock {
                                            Button(action: { securityService.authenticate() }) {
                                                Image(systemName: securityService.biometricIconName)
                                                    .font(.system(size: 22, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .frame(width: 56, height: 56)
                                            }
                                            .buttonStyle(SystemPasscodeUtilityButtonStyle(accentColor: Color(UIColor.systemBlue)))
                                        }

                                        Button(action: { verifyPin() }) {
                                            Text(NSLocalizedString("Unlock", comment: ""))
                                                .font(.system(size: 17, weight: .semibold))
                                                .foregroundColor(.white)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 56)
                                        }
                                        .buttonStyle(LockPrimaryUnlockButtonStyle())
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .lockSurfacePanel(cornerRadius: 34)
                            .frame(maxWidth: 360)

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .ignoresSafeArea(
                .container,
                edges: (!isPadDeviceLandscape(geo: geo) && geo.size.width > geo.size.height) ? .horizontal : []
            )
            .onAppear {
                _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
            }
        }
    }

    @ViewBuilder
    private func simplePinLayout(in geo: GeometryProxy, isLandscape: Bool, isPad: Bool) -> some View {
        if isLandscape && !isPad {
            simplePinPhoneLandscapeLayout(in: geo)
        } else {
            simplePinPortraitLayout(isPad: isPad)
        }
    }

    private func simplePinPhoneLandscapeLayout(in geo: GeometryProxy) -> some View {
        let buttonSize: CGFloat = 62
        let spacing: CGFloat = 12
        let hSpacing: CGFloat = 18
        let columnGap: CGFloat = 28
        let keypadWidth = buttonSize * 3 + hSpacing * 2
        let infoWidth = min(max(geo.size.width * 0.22, 180), 220)

        return HStack(spacing: columnGap) {
            VStack(spacing: 20) {
                LockTitleView(
                    iconSize: 84,
                    titleFont: .title3,
                    titleLineLimit: 2
                )

                LockPinDotsView(
                    pinCount: pin.count,
                    totalCount: 4,
                    dotSize: 12,
                    spacing: 14,
                    shakeOffset: shakeDegrees
                )
            }
            .frame(width: infoWidth)

            LockKeypadView(
                securityService: securityService,
                buttonSize: buttonSize,
                spacing: spacing,
                hSpacing: hSpacing,
                onPress: { appendPin($0) },
                onDelete: { if !pin.isEmpty { pin.removeLast() } },
                onBiometric: { securityService.authenticate() }
            )
            .frame(width: keypadWidth)
        }
        .frame(maxWidth: infoWidth + keypadWidth + columnGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func simplePinPortraitLayout(isPad: Bool) -> some View {
        VStack(spacing: isPad ? 38 : 34) {
            Spacer()

            LockTitleView(
                iconSize: isPad ? 112 : 100,
                titleFont: .title2,
                titleLineLimit: 2
            )

            LockPinDotsView(
                pinCount: pin.count,
                totalCount: 4,
                dotSize: isPad ? 18 : 16,
                spacing: isPad ? 22 : 20,
                shakeOffset: shakeDegrees
            )

            LockKeypadView(
                securityService: securityService,
                buttonSize: isPad ? 82 : 75,
                spacing: isPad ? 18 : 15,
                hSpacing: isPad ? 34 : 30,
                onPress: { appendPin($0) },
                onDelete: { if !pin.isEmpty { pin.removeLast() } },
                onBiometric: { securityService.authenticate() }
            )
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: isPad ? 460 : .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, isPad ? 32 : 20)
        .padding(.bottom, isPad ? 34 : 22)
    }

    private func appendPin(_ char: String) {
        if pin.count < 4 {
            let willCompletePin = pin.count == 3
            if !willCompletePin {
                triggerPasscodeKeyFeedback(style: .light)
            }
            pin.append(char)
            if pin.count == 4 {
                verifyPin()
            }
        }
    }

    private func verifyPin() {
        if securityService.unlock(with: pin) {
            triggerPasscodeResultFeedback(success: true)
            pin = ""
        } else {
            triggerPasscodeResultFeedback(success: false)
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.42, blendDuration: 0.08)) {
                shakeDegrees = 14
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.42, blendDuration: 0.08)) {
                    shakeDegrees = -14
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.58, blendDuration: 0.08)) {
                    shakeDegrees = 0
                    pin = ""
                }
            }
        }
    }

    private func isPadDeviceLandscape(geo: GeometryProxy) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && geo.size.width > geo.size.height
    }
}

struct LockKeypadView: View {
    @ObservedObject var securityService: SecurityService
    let buttonSize: CGFloat
    let spacing: CGFloat
    let hSpacing: CGFloat
    let onPress: (String) -> Void
    let onDelete: () -> Void
    let onBiometric: () -> Void

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<3) { row in
                HStack(spacing: hSpacing) {
                    ForEach(1..<4) { col in
                        let number = row * 3 + col
                        KeypadButton(number: "\(number)", size: buttonSize) {
                            onPress("\(number)")
                        }
                    }
                }
            }

            HStack(spacing: hSpacing) {
                if securityService.shouldShowBiometricUnlock {
                    Button(action: {
                        triggerPasscodeKeyFeedback(style: .medium)
                        onBiometric()
                    }) {
                        Image(systemName: securityService.biometricIconName)
                            .font(.system(size: buttonSize * 0.34, weight: .semibold))
                            .frame(width: buttonSize, height: buttonSize)
                            .foregroundColor(.white)
                    }
                    .buttonStyle(SystemPasscodeUtilityButtonStyle(accentColor: Color(UIColor.systemBlue)))
                } else {
                    Color.clear.frame(width: buttonSize, height: buttonSize)
                }

                KeypadButton(number: "0", size: buttonSize) {
                    onPress("0")
                }

                Button(action: {
                    triggerPasscodeKeyFeedback(style: .rigid)
                    onDelete()
                }) {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: buttonSize * 0.30, weight: .semibold))
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundColor(.white)
                }
                .buttonStyle(SystemPasscodeUtilityButtonStyle(accentColor: Color(UIColor.systemOrange)))
                .accessibilityLabel(Text(NSLocalizedString("Delete", comment: "")))
            }
        }
    }
}

struct KeypadButton: View {
    let number: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: {
            triggerPasscodeKeyFeedback(style: .light)
            action()
        }) {
            Text(number)
                .font(.system(size: size * 0.40, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
                .foregroundColor(.white)
        }
        .buttonStyle(SystemPasscodeNumberButtonStyle())
    }
}

private struct LockScreenBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.06, green: 0.09, blue: 0.16),
                    Color(red: 0.06, green: 0.13, blue: 0.24),
                    Color(red: 0.03, green: 0.05, blue: 0.10)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                gradient: Gradient(colors: [
                    Color(UIColor.systemBlue).opacity(0.22),
                    Color(UIColor.systemIndigo).opacity(0.08),
                    Color.clear
                ]),
                center: .topLeading,
                startRadius: 24,
                endRadius: 320
            )
            .ignoresSafeArea()

            RadialGradient(
                gradient: Gradient(colors: [
                    Color(UIColor.systemTeal).opacity(0.22),
                    Color.clear
                ]),
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 380
            )
            .ignoresSafeArea()

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.04),
                    Color.black.opacity(0.40)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

private struct LockTitleView: View {
    let iconSize: CGFloat
    let titleFont: Font
    let titleLineLimit: Int

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.16),
                                Color.white.opacity(0.04)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 8)
                    .padding(6)

                Image(systemName: "lock.fill")
                    .font(.system(size: iconSize * 0.34, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: iconSize, height: iconSize)
            .shadow(color: Color(UIColor.systemBlue).opacity(0.18), radius: 22, x: 0, y: 14)

            Text(NSLocalizedString("Security Locked", comment: "Lock Screen Title"))
                .font(titleFont)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(titleLineLimit)
        }
    }
}

private struct LockPinDotsView: View {
    let pinCount: Int
    let totalCount: Int
    let dotSize: CGFloat
    let spacing: CGFloat
    let shakeOffset: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<totalCount) { index in
                let isFilled = index < pinCount

                Circle()
                    .fill(isFilled ? Color.white : Color.white.opacity(0.18))
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isFilled ? 0.30 : 0.10), lineWidth: 1)
                    )
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(isFilled ? 1.0 : 0.92)
                    .shadow(
                        color: isFilled ? Color(UIColor.systemBlue).opacity(0.24) : Color.clear,
                        radius: 8,
                        x: 0,
                        y: 4
                    )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .offset(x: shakeOffset)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.76, blendDuration: 0.08), value: pinCount)
    }
}

private struct LockFieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.03)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct LockSurfacePanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 26)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.08),
                                        Color.white.opacity(0.02)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 28, x: 0, y: 18)
            .shadow(color: Color(UIColor.systemBlue).opacity(0.10), radius: 24, x: 0, y: 10)
    }
}

private extension View {
    func lockSurfacePanel(cornerRadius: CGFloat) -> some View {
        modifier(LockSurfacePanelModifier(cornerRadius: cornerRadius))
    }
}

private struct SystemPasscodeNumberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        return configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(isPressed ? 0.40 : 0.12))
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.16),
                                        Color.white.opacity(0.04)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(isPressed ? 0.22 : 0.14), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.90 : 1.0)
            .brightness(isPressed ? 0.05 : 0.0)
            .shadow(
                color: Color(UIColor.systemBlue).opacity(isPressed ? 0.10 : 0.18),
                radius: isPressed ? 10 : 18,
                x: 0,
                y: isPressed ? 4 : 10
            )
            .shadow(
                color: Color.black.opacity(isPressed ? 0.18 : 0.28),
                radius: isPressed ? 8 : 18,
                x: 0,
                y: isPressed ? 4 : 12
            )
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.74, blendDuration: 0.08), value: isPressed)
    }
}

private struct SystemPasscodeUtilityButtonStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(accentColor.opacity(isPressed ? 0.24 : 0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.14),
                                        accentColor.opacity(0.10)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(isPressed ? 0.22 : 0.14), lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .brightness(isPressed ? 0.05 : 0.0)
            .shadow(
                color: accentColor.opacity(isPressed ? 0.10 : 0.18),
                radius: isPressed ? 10 : 18,
                x: 0,
                y: isPressed ? 4 : 10
            )
            .shadow(
                color: Color.black.opacity(isPressed ? 0.18 : 0.28),
                radius: isPressed ? 8 : 18,
                x: 0,
                y: isPressed ? 4 : 12
            )
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.76, blendDuration: 0.08), value: isPressed)
    }
}

private struct LockPrimaryUnlockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(UIColor.systemBlue).opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.14),
                                        Color(UIColor.systemIndigo).opacity(0.22)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .brightness(isPressed ? 0.05 : 0.0)
            .shadow(
                color: Color(UIColor.systemBlue).opacity(isPressed ? 0.12 : 0.24),
                radius: isPressed ? 10 : 20,
                x: 0,
                y: isPressed ? 4 : 12
            )
            .shadow(
                color: Color.black.opacity(isPressed ? 0.16 : 0.24),
                radius: isPressed ? 8 : 16,
                x: 0,
                y: isPressed ? 4 : 12
            )
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.80, blendDuration: 0.08), value: isPressed)
    }
}

private func triggerPasscodeKeyFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
    let generator = UIImpactFeedbackGenerator(style: style)
    generator.prepare()
    generator.impactOccurred()
}

private func triggerPasscodeResultFeedback(success: Bool) {
    let generator = UINotificationFeedbackGenerator()
    generator.prepare()
    generator.notificationOccurred(success ? .success : .error)
}

#endif
