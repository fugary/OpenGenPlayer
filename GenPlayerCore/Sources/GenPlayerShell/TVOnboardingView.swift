#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVFirstLaunchOnboardingView: View {
    let onClose: () -> Void

    @State private var pageIndex = 0
    @State private var lastActionTime: Double = 0
    @FocusState private var focusedButton: String?

    private let pages: [TVOnboardingPage] = [
        TVOnboardingPage(
            icon: "network",
            titleKey: "Platform Shell TV Onboarding Network Title",
            bodyKey: "Platform Shell TV Onboarding Network Body",
            highlightKeys: [
                "Platform Shell TV Onboarding Network Highlight 1",
                "Platform Shell TV Onboarding Network Highlight 2",
                "Platform Shell TV Onboarding Network Highlight 3"
            ],
            accent: TVShellStyle.accentSoft
        ),
        TVOnboardingPage(
            icon: "person.crop.circle.fill",
            titleKey: "Platform Shell TV Onboarding My Title",
            bodyKey: "Platform Shell TV Onboarding My Body",
            highlightKeys: [
                "Platform Shell TV Onboarding My Highlight 1",
                "Platform Shell TV Onboarding My Highlight 2",
                "Platform Shell TV Onboarding My Highlight 3"
            ],
            accent: Color(red: 0.62, green: 0.68, blue: 1.0)
        ),
        TVOnboardingPage(
            icon: "button.programmable",
            titleKey: "Platform Shell TV Onboarding Remote Title",
            bodyKey: "Platform Shell TV Onboarding Remote Body",
            highlightKeys: [
                "Platform Shell TV Onboarding Remote Highlight 1",
                "Platform Shell TV Onboarding Remote Highlight 2",
                "Platform Shell TV Onboarding Remote Highlight 3"
            ],
            accent: Color(red: 0.44, green: 0.82, blue: 0.60)
        ),
        TVOnboardingPage(
            icon: "gearshape.fill",
            titleKey: "Platform Shell TV Onboarding Settings Title",
            bodyKey: "Platform Shell TV Onboarding Settings Body",
            highlightKeys: [
                "Platform Shell TV Onboarding Settings Highlight 1",
                "Platform Shell TV Onboarding Settings Highlight 2",
                "Platform Shell TV Onboarding Settings Highlight 3"
            ],
            accent: Color(red: 0.92, green: 0.68, blue: 0.36)
        )
    ]

    private var currentPage: TVOnboardingPage {
        pages[min(max(pageIndex, 0), pages.count - 1)]
    }

    private var isFirstPage: Bool {
        pageIndex == 0
    }

    private var isLastPage: Bool {
        pageIndex == pages.count - 1
    }

    var body: some View {
        ZStack {
            TVCinematicBackground()
                .ignoresSafeArea()

            Color.black.opacity(0.54)
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 74) {
                TVOnboardingPreviewCard(page: currentPage, pageIndex: pageIndex, totalPages: pages.count)
                    .frame(width: 560, height: 610)
                    .opacity(0.80)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(platformShellString("Platform Shell TV Onboarding Eyebrow"))
                            .font(.system(size: 21, weight: .heavy))
                            .foregroundColor(currentPage.accent)
                            .lineLimit(1)

                        Text(platformShellString(currentPage.titleKey))
                            .font(.system(size: 56, weight: .heavy))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.70)

                        Text(platformShellString(currentPage.bodyKey))
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundColor(.white.opacity(0.72))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(currentPage.highlightKeys, id: \.self) { key in
                            TVOnboardingHighlightRow(text: platformShellString(key), accent: currentPage.accent)
                        }
                    }
                    .padding(.top, 4)

                    TVOnboardingPageIndicator(count: pages.count, currentIndex: pageIndex, accent: currentPage.accent)
                        .padding(.top, 4)

                    HStack(spacing: 16) {
                        Button(action: {
                            guard isActionAllowed() else { return }
                            onClose()
                        }) {
                            TVOnboardingActionButton(
                                title: platformShellString("Skip"),
                                systemImageName: "xmark",
                                width: 156,
                                isPrimary: false,
                                accent: currentPage.accent
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                        .focused($focusedButton, equals: "skip")

                        if !isFirstPage {
                            Button(action: previousPage) {
                                TVOnboardingActionButton(
                                    title: platformShellString("Back"),
                                    systemImageName: "chevron.left",
                                    width: 156,
                                    isPrimary: false,
                                    accent: currentPage.accent
                                )
                            }
                            .buttonStyle(TVPlainButtonStyle())
                            .tvDisableSystemFocusEffect()
                            .focused($focusedButton, equals: "previous")
                        }

                        Button(action: primaryAction) {
                            TVOnboardingActionButton(
                                title: platformShellString(isLastPage ? "Get Started" : "Next"),
                                systemImageName: isLastPage ? "checkmark" : "chevron.right",
                                width: isLastPage ? 220 : 156,
                                isPrimary: true,
                                accent: currentPage.accent
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                        .focused($focusedButton, equals: "primary")
                    }
                    .padding(.top, 12)
                    .tvFocusSectionIfAvailable()
                }
                .frame(width: 770, alignment: .leading)
            }
            .padding(.horizontal, 96)
        }
        .onAppear(perform: preparePrimaryFocus)
        .onChange(of: pageIndex) { _ in
            preparePrimaryFocus()
        }
        .onExitCommand {
            if isFirstPage {
                onClose()
            } else {
                previousPage()
            }
        }
    }

    private func isActionAllowed() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastActionTime > 0.35 else { return false }
        lastActionTime = now
        return true
    }

    private func primaryAction() {
        guard isActionAllowed() else { return }
        if isLastPage {
            onClose()
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                pageIndex = min(pageIndex + 1, pages.count - 1)
            }
        }
    }

    private func previousPage() {
        guard isActionAllowed() else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            pageIndex = max(pageIndex - 1, 0)
        }
    }

    private func preparePrimaryFocus() {
        focusedButton = "primary"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedButton = "primary"
        }
    }
}



struct TVOnboardingPage {
    let icon: String
    let titleKey: String
    let bodyKey: String
    let highlightKeys: [String]
    let accent: Color
}



struct TVOnboardingPreviewCard: View {
    let page: TVOnboardingPage
    let pageIndex: Int
    let totalPages: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.white.opacity(0.060))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(page.accent.opacity(0.24))

                        Image(systemName: page.icon)
                            .font(.system(size: 46, weight: .bold))
                            .foregroundColor(page.accent)
                    }
                    .frame(width: 96, height: 96)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(TVBrandIdentity.displayName)
                            .font(.system(size: 31, weight: .heavy))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(String(format: platformShellString("Platform Shell TV Onboarding Progress Format"), pageIndex + 1, totalPages))
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white.opacity(0.58))
                    }
                }

                TVOnboardingMockTabs(activeIndex: pageIndex, accentColor: page.accent)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<3, id: \.self) { index in
                        TVOnboardingMockRow(
                            title: platformShellString(page.highlightKeys[index]),
                            accent: index == 0 ? page.accent : Color.white.opacity(0.32),
                            isEmphasized: index == 0
                        )
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(38)

            // Upper right "Interface Preview" watermark badge
            HStack {
                Spacer()
                Text(platformShellString("Platform Shell TV Onboarding Preview Badge"))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(.white.opacity(0.26))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            }
            .padding(.top, 24)
            .padding(.trailing, 24)
        }
        .shadow(color: Color.black.opacity(0.30), radius: 28, x: 0, y: 18)
    }
}



struct TVOnboardingMockTabs: View {
    let activeIndex: Int
    let accentColor: Color

    private let items: [(String, String)] = [
        ("network", "Network"),
        ("person.crop.circle.fill", "My"),
        ("gearshape", "Settings")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let isActive = index == min(activeIndex, 2)
                HStack(spacing: 6) {
                    Image(systemName: item.0)
                        .font(.system(size: 15, weight: .bold))
                    Text(platformShellString(item.1))
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(isActive ? accentColor : Color.white.opacity(0.34))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? accentColor.opacity(0.24) : Color.white.opacity(0.04))
                )
            }
        }
    }
}



struct TVOnboardingMockRow: View {
    let title: String
    let accent: Color
    let isEmphasized: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(isEmphasized ? 0.82 : 0.34))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: isEmphasized ? "play.fill" : "circle.fill")
                        .font(.system(size: isEmphasized ? 24 : 12, weight: .bold))
                        .foregroundColor(isEmphasized ? .black.opacity(0.78) : .white.opacity(0.56))
                )

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(isEmphasized ? .white.opacity(0.92) : .white.opacity(0.62))
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 96)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(isEmphasized ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        )
    }
}



struct TVOnboardingHighlightRow: View {
    let text: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(accent)
                .padding(.top, 2)

            Text(text)
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}



struct TVOnboardingPageIndicator: View {
    let count: Int
    let currentIndex: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentIndex ? accent : Color.white.opacity(0.20))
                    .frame(width: index == currentIndex ? 34 : 12, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: currentIndex)
    }
}



struct TVOnboardingActionButton: View {
    let title: String
    let systemImageName: String
    let width: CGFloat
    let isPrimary: Bool
    let accent: Color

    @Environment(\.isFocused) private var isFocused

    private var foregroundColor: Color {
        if isFocused {
            return Color.black.opacity(0.90)
        }
        return isPrimary ? Color.black.opacity(0.88) : .white.opacity(0.76)
    }

    private var fillColor: Color {
        if isFocused {
            return Color.white.opacity(0.96)
        }
        return isPrimary ? accent.opacity(0.94) : Color.white.opacity(0.10)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 21, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Image(systemName: systemImageName)
                .font(.system(size: 19, weight: .heavy))
        }
        .foregroundColor(foregroundColor)
        .frame(width: width, height: 64)
        .background(
            Capsule(style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isFocused ? Color.clear : Color.white.opacity(isPrimary ? 0.10 : 0.14), lineWidth: 1)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: 32, showsFocus: isFocused, outerLineWidth: 3, innerInset: 3))
        .scaleEffect(isFocused ? 1.035 : 1.0)
        .shadow(color: isFocused ? Color.black.opacity(0.30) : .clear, radius: isFocused ? 18 : 0, x: 0, y: isFocused ? 8 : 0)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .modifier(TVFocusedCardLayerModifier())
    }
}



struct TVRootPageScrollView<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                content()
            }
            .padding(.horizontal, TVPageContentMetrics.horizontalPadding)
            .padding(.top, 24)
            .padding(.bottom, 86)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tvFocusSectionIfAvailable()
        .background(TVCinematicBackground())
        .navigationBarHidden(true)
    }
}
#endif
