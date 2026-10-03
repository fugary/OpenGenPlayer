#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1.0)
    }
}

struct TVFocusableSectionButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.06) : Color.clear)
            )
            .brightness(isFocused ? 0.04 : 0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}



struct TVCinematicBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                darkBackground
            } else {
                lightBackground
            }
        }
        .ignoresSafeArea()
    }

    private var darkBackground: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.035, green: 0.038, blue: 0.048),
                    TVShellStyle.background,
                    Color(red: 0.008, green: 0.011, blue: 0.016)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                gradient: Gradient(colors: [
                    TVShellStyle.accent.opacity(0.035),
                    Color.clear,
                    Color(red: 0.05, green: 0.14, blue: 0.22).opacity(0.16)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.52),
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.72)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var lightBackground: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.97, green: 0.98, blue: 0.99),
                    TVShellStyle.background,
                    Color(red: 0.83, green: 0.88, blue: 0.94)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                gradient: Gradient(colors: [
                    TVShellStyle.accent.opacity(0.12),
                    Color.clear,
                    Color(red: 0.36, green: 0.52, blue: 0.70).opacity(0.14)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.38),
                    Color.clear,
                    Color.black.opacity(0.06)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}



extension View {
    @ViewBuilder
    func tvSettingsNavigationZoomSource(
        sourceID: String,
        in namespace: Namespace.ID?
    ) -> some View {
        if let namespace, #available(tvOS 18.0, *) {
            matchedTransitionSource(id: sourceID, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func tvSettingsNavigationZoomDestination(
        sourceID: String,
        in namespace: Namespace.ID?
    ) -> some View {
        if let namespace, #available(tvOS 18.0, *) {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}



extension View {
    @ViewBuilder
    func tvFocusSectionIfAvailable() -> some View {
        if #available(tvOS 15.0, *) {
            self.focusSection()
        } else {
            self
        }
    }

    func tvShelfCard(width: CGFloat = 320, minHeight: CGFloat = 220) -> some View {
        self
            .frame(width: width, alignment: .topLeading)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .padding(24)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .modifier(
                TVSurfaceModifier(
                    cornerRadius: 28,
                    baseFill: TVShellStyle.surface,
                    focusedFill: TVShellStyle.elevatedSurface,
                    baseStroke: TVShellStyle.glassStroke,
                    focusedStroke: Color.white.opacity(0.28),
                    focusedScale: 1.04,
                    shadowOpacity: 0.36
                )
            )
            .modifier(TVFocusedCardLayerModifier())
    }

    func tvServerShelfCard(width: CGFloat = 420, height: CGFloat = 104) -> some View {
        self
            .frame(width: width, height: height, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .modifier(
                TVSurfaceModifier(
                    cornerRadius: 26,
                    baseFill: TVShellStyle.surface,
                    focusedFill: TVShellStyle.elevatedSurface,
                    baseStroke: TVShellStyle.glassStroke,
                    focusedStroke: Color.white.opacity(0.28),
                    focusedScale: 1.04,
                    shadowOpacity: 0.36
                )
            )
            .modifier(TVFocusedCardLayerModifier())
    }

    func tvPosterShelfCard(
        width: CGFloat = 270,
        minHeight: CGFloat = 470,
        focusedScale: CGFloat = 1.045
    ) -> some View {
        self
            .frame(width: width, alignment: .topLeading)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .modifier(TVPosterFocusModifier(cornerRadius: 14, focusedScale: focusedScale))
            .modifier(TVFocusedCardLayerModifier())
    }

    func tvFocusedPosterArtwork(cornerRadius: CGFloat) -> some View {
        self.modifier(TVPosterArtworkFocusModifier(cornerRadius: cornerRadius))
    }

    func tvFocusedCircleArtwork() -> some View {
        self.modifier(TVCircleArtworkFocusModifier())
    }

    func tvGridCard(minHeight: CGFloat = 220) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .padding(24)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .modifier(
                TVSurfaceModifier(
                    cornerRadius: 28,
                    baseFill: TVShellStyle.surface,
                    focusedFill: TVShellStyle.elevatedSurface,
                    baseStroke: TVShellStyle.glassStroke,
                    focusedStroke: Color.white.opacity(0.28),
                    focusedScale: 1.03,
                    shadowOpacity: 0.34
                )
            )
            .modifier(TVFocusedCardLayerModifier())
    }

    func tvDetailPanel() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(28)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .modifier(
                TVSurfaceModifier(
                    cornerRadius: 26,
                    baseFill: TVShellStyle.surface,
                    focusedFill: TVShellStyle.elevatedSurface,
                    baseStroke: TVShellStyle.glassStroke,
                    focusedStroke: Color.white.opacity(0.24),
                    focusedScale: 1.018,
                    shadowOpacity: 0.30
                )
            )
            .modifier(TVFocusedCardLayerModifier())
    }

    func tvInteractiveRowPanel() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(28)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .modifier(TVInteractiveRowSurfaceModifier())
            .modifier(TVFocusedCardLayerModifier())
    }

    @ViewBuilder
    func tvDisableSystemFocusEffect() -> some View {
        if #available(tvOS 17.0, *) {
            self.focusEffectDisabled(true)
        } else {
            self
        }
    }
}



struct TVFocusedBlockOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let showsFocus: Bool
    var outerLineWidth: CGFloat = 3.4
    var innerInset: CGFloat = 3
    var innerLineWidth: CGFloat = 1

    private var innerStroke: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.52)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    showsFocus ? TVShellStyle.focusStroke : Color.clear,
                    lineWidth: showsFocus ? outerLineWidth : 0
                )

            RoundedRectangle(cornerRadius: max(1, cornerRadius - innerInset), style: .continuous)
                .strokeBorder(
                    showsFocus ? innerStroke : Color.clear,
                    lineWidth: showsFocus ? innerLineWidth : 0
                )
                .padding(innerInset)
        }
    }
}



struct TVSurfaceModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    let cornerRadius: CGFloat
    let baseFill: Color
    let focusedFill: Color
    let baseStroke: Color
    let focusedStroke: Color
    let focusedScale: CGFloat
    let shadowOpacity: Double

    func body(content: Content) -> some View {
        let showsFocus = isFocused && isEnabled

        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(showsFocus ? focusedFill : baseFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(showsFocus ? Color.clear : baseStroke, lineWidth: 1)
            )
            .overlay(TVFocusedBlockOverlay(cornerRadius: cornerRadius, showsFocus: showsFocus))
            .scaleEffect(showsFocus ? focusedScale : 1.0)
            .brightness(showsFocus ? 0.02 : 0)
            .shadow(
                color: showsFocus ? Color.black.opacity(shadowOpacity) : .clear,
                radius: showsFocus ? 22 : 0,
                x: 0,
                y: showsFocus ? 12 : 0
            )
            .shadow(
                color: showsFocus ? focusedStroke.opacity(0.16) : .clear,
                radius: showsFocus ? 16 : 0,
                x: 0,
                y: 0
            )
            .animation(.easeOut(duration: 0.18), value: showsFocus)
            .tvDisableSystemFocusEffect()
    }
}



struct TVFileBrowserCardBackground: View {
    let showsFocus: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        let baseColor = colorScheme == .dark ? Color.white : Color.black
        return showsFocus ? baseColor.opacity(0.085) : baseColor.opacity(0.055)
    }

    private var borderColor: Color {
        let baseColor = colorScheme == .dark ? Color.white : Color.black
        return showsFocus ? Color.clear : baseColor.opacity(0.10)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(fillColor)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(borderColor, lineWidth: 1)

            TVFocusedBlockOverlay(cornerRadius: 22, showsFocus: showsFocus)
        }
    }
}



struct TVFileBrowserCardModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let showsFocus = isFocused && isEnabled

        content
            .background(TVFileBrowserCardBackground(showsFocus: showsFocus))
            .scaleEffect(showsFocus ? 1.026 : 1.0)
            .brightness(showsFocus ? 0.035 : 0)
            .shadow(
                color: showsFocus ? Color.black.opacity(0.42) : Color.black.opacity(0.08),
                radius: showsFocus ? 24 : 9,
                x: 0,
                y: showsFocus ? 14 : 5
            )
            .shadow(
                color: showsFocus ? TVShellStyle.focusStroke.opacity(0.16) : .clear,
                radius: showsFocus ? 16 : 0,
                x: 0,
                y: 0
            )
            .animation(.easeOut(duration: 0.16), value: showsFocus)
            .tvDisableSystemFocusEffect()
    }
}



struct TVInteractiveRowSurfaceModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let showsFocus = isFocused && isEnabled

        content
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(showsFocus ? TVRowFocusStyle.focusedFill(for: colorScheme) : TVShellStyle.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(showsFocus ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
            )
            .scaleEffect(showsFocus ? 1.014 : 1.0)
            .shadow(
                color: showsFocus ? Color.black.opacity(0.26) : .clear,
                radius: showsFocus ? 18 : 0,
                x: 0,
                y: showsFocus ? 10 : 0
            )
            .animation(.easeOut(duration: 0.16), value: showsFocus)
            .tvDisableSystemFocusEffect()
    }
}



struct TVPosterFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    let cornerRadius: CGFloat
    let focusedScale: CGFloat

    func body(content: Content) -> some View {
        let showsFocus = isFocused && isEnabled

        content
            .scaleEffect(showsFocus ? focusedScale : 1.0)
            .brightness(showsFocus ? 0.035 : 0)
            .shadow(
                color: showsFocus ? Color.black.opacity(0.48) : Color.black.opacity(0.10),
                radius: showsFocus ? 30 : 8,
                x: 0,
                y: showsFocus ? 18 : 4
            )
            .shadow(
                color: showsFocus ? TVShellStyle.focusStroke.opacity(0.16) : .clear,
                radius: showsFocus ? 18 : 0,
                x: 0,
                y: 0
            )
            .animation(.easeOut(duration: 0.18), value: showsFocus)
            .tvDisableSystemFocusEffect()
    }
}



struct TVPosterArtworkFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let showsFocus = isFocused && isEnabled

        content
            .overlay(TVFocusedBlockOverlay(cornerRadius: cornerRadius, showsFocus: showsFocus, outerLineWidth: 3.5))
            .shadow(
                color: showsFocus ? TVShellStyle.focusStroke.opacity(0.20) : .clear,
                radius: showsFocus ? 18 : 0,
                x: 0,
                y: 0
            )
            .animation(.easeOut(duration: 0.16), value: showsFocus)
    }
}



struct TVCircleArtworkFocusModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let showsFocus = isFocused && isEnabled

        content
            .overlay(
                Circle()
                    .strokeBorder(showsFocus ? Color.white.opacity(0.96) : Color.clear, lineWidth: showsFocus ? 3.5 : 0)
            )
            .overlay(
                Circle()
                    .strokeBorder(showsFocus ? Color.black.opacity(0.24) : Color.clear, lineWidth: showsFocus ? 1 : 0)
                    .padding(3)
            )
            .shadow(
                color: showsFocus ? Color.white.opacity(0.18) : .clear,
                radius: showsFocus ? 14 : 0,
                x: 0,
                y: 0
            )
            .animation(.easeOut(duration: 0.16), value: showsFocus)
    }
}



struct TVFocusedCardLayerModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.zIndex(isFocused ? 100 : 0)
    }
}

struct TVAppThemeModifier: ViewModifier {
    @AppStorage("userTheme") private var userTheme: String = "System"

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(userTheme == "Dark" ? .dark : (userTheme == "Light" ? .light : nil))
    }
}

extension View {
    func tvApplyAppTheme() -> some View {
        self.modifier(TVAppThemeModifier())
    }
}
#endif
