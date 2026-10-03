import SwiftUI

public struct AppStartupFlowRootView<Content: View>: View {
    let appLanguage: String
    public static var onboardingVersion: String { "1.0.0" }
    let content: () -> Content

    @AppStorage("onboardingCompletedVersion") private var onboardingCompletedVersion: String = ""
    @AppStorage("onboardingForceReplay") private var onboardingForceReplay: Bool = false

    @State private var isSplashVisible = true
    @State private var isOnboardingVisible = false
    @State private var hasResolvedStartup = false

    public init(appLanguage: String, @ViewBuilder content: @escaping () -> Content) {
        self.appLanguage = appLanguage
        self.content = content
    }

    public var body: some View {

        ZStack {
            content()
                .disabled(isSplashVisible || isOnboardingVisible)

            if isSplashVisible {
                LaunchSplashView()
                    .transition(.opacity)
                    .zIndex(2)
            }

            if isOnboardingVisible {
#if os(macOS)
                MacWelcomeView(onClose: completeOnboarding)
                    .transition(.opacity)
                    .zIndex(3)
#else
                FirstLaunchOnboardingView(onClose: completeOnboarding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
#endif
            }
        }
        .onAppear {
            resolveStartupFlowIfNeeded()
        }
        .onChange(of: onboardingForceReplay) { shouldReplay in
            guard shouldReplay else { return }
            onboardingForceReplay = false
            withAnimation(.easeInOut(duration: 0.25)) {
                isOnboardingVisible = true
            }
        }
    }

    private func resolveStartupFlowIfNeeded() {
        guard !hasResolvedStartup else { return }
        hasResolvedStartup = true

        let shouldShowOnboarding = onboardingCompletedVersion != Self.onboardingVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.24)) {
                isSplashVisible = false
            }

            guard shouldShowOnboarding else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isOnboardingVisible = true
                }
            }
        }
    }

    private func completeOnboarding() {
        onboardingCompletedVersion = Self.onboardingVersion
        withAnimation(.easeInOut(duration: 0.25)) {
            isOnboardingVisible = false
        }
    }
}

private struct LaunchSplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animatePulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    colorScheme == .dark ? Color(red: 0.03, green: 0.08, blue: 0.15) : Color(red: 0.93, green: 0.97, blue: 1.0),
                    colorScheme == .dark ? Color(red: 0.06, green: 0.16, blue: 0.29) : Color(red: 0.84, green: 0.91, blue: 0.99),
                    colorScheme == .dark ? Color(red: 0.03, green: 0.12, blue: 0.24) : Color(red: 0.89, green: 0.95, blue: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill((colorScheme == .dark ? Color.white : Color(red: 0.16, green: 0.42, blue: 0.80)).opacity(colorScheme == .dark ? 0.16 : 0.12))
                .frame(width: 260, height: 260)
                .offset(x: animatePulse ? 86 : -32, y: animatePulse ? -210 : -132)
                .blur(radius: 10)

            Circle()
                .fill((colorScheme == .dark ? Color.white : Color(red: 0.09, green: 0.58, blue: 0.67)).opacity(colorScheme == .dark ? 0.08 : 0.10))
                .frame(width: 300, height: 300)
                .offset(x: animatePulse ? -110 : 54, y: animatePulse ? 196 : 128)
                .blur(radius: 14)

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.82))
                        .frame(width: 102, height: 102)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 16, x: 0, y: 10)

                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundColor(colorScheme == .dark ? .white : Color(red: 0.10, green: 0.27, blue: 0.50))
                }
                .scaleEffect(animatePulse ? 1.04 : 0.96)

                VStack(spacing: 8) {
                    Text(platformShellString("Gen Player"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(colorScheme == .dark ? .white : Color(red: 0.09, green: 0.23, blue: 0.43))

                    Text(platformShellString("Launch Splash Subtitle"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.72) : Color(red: 0.21, green: 0.36, blue: 0.58))
                        .tracking(0.4)
                }
            }
            .padding(.bottom, 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                animatePulse = true
            }
        }
    }
}

struct FirstLaunchOnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onClose: () -> Void

    @State private var pageIndex = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            stepKey: "Onboarding Welcome Step",
            titleKey: "Onboarding Welcome Title",
            descriptionKey: "Onboarding Welcome Body",
            highlightKeys: [
                "Onboarding Welcome Highlight 1",
                "Onboarding Welcome Highlight 2",
                "Onboarding Welcome Highlight 3"
            ],
            chipKeys: [
                "Onboarding Welcome Chip 1",
                "Onboarding Welcome Chip 2",
                "Onboarding Welcome Chip 3"
            ],
            routeTitleKey: "Onboarding Welcome Route Title",
            routeValueKey: "Onboarding Welcome Route Value",
            noteTitleKey: "Onboarding Welcome Note Title",
            noteBodyKey: "Onboarding Welcome Note Body",
            preview: .hub,
            palette: OnboardingPalette(
                primary: Color(red: 0.10, green: 0.44, blue: 0.78),
                secondary: Color(red: 0.11, green: 0.68, blue: 0.69),
                glow: Color(red: 0.84, green: 0.94, blue: 1.0)
            )
        ),
        OnboardingPage(
            stepKey: "Onboarding Source Step",
            titleKey: "Onboarding Source Title",
            descriptionKey: "Onboarding Source Body",
            highlightKeys: [
                "Onboarding Source Highlight 1",
                "Onboarding Source Highlight 2",
                "Onboarding Source Highlight 3"
            ],
            chipKeys: [
                "Onboarding Source Chip 1",
                "Onboarding Source Chip 2",
                "Onboarding Source Chip 3"
            ],
            routeTitleKey: "Onboarding Source Route Title",
            routeValueKey: "Onboarding Source Route Value",
            noteTitleKey: "Onboarding Source Note Title",
            noteBodyKey: "Onboarding Source Note Body",
            preview: .sources,
            palette: OnboardingPalette(
                primary: Color(red: 0.14, green: 0.53, blue: 0.44),
                secondary: Color(red: 0.11, green: 0.47, blue: 0.79),
                glow: Color(red: 0.88, green: 0.97, blue: 0.93)
            )
        ),
        OnboardingPage(
            stepKey: "Onboarding Privacy Step",
            titleKey: "Onboarding Privacy Title",
            descriptionKey: "Onboarding Privacy Body",
            highlightKeys: [
                "Onboarding Privacy Highlight 1",
                "Onboarding Privacy Highlight 2",
                "Onboarding Privacy Highlight 3"
            ],
            chipKeys: [
                "Onboarding Privacy Chip 1",
                "Onboarding Privacy Chip 2",
                "Onboarding Privacy Chip 3"
            ],
            routeTitleKey: "Onboarding Privacy Route Title",
            routeValueKey: "Onboarding Privacy Route Value",
            noteTitleKey: "Onboarding Privacy Note Title",
            noteBodyKey: "Onboarding Privacy Note Body",
            preview: .privacy,
            palette: OnboardingPalette(
                primary: Color(red: 0.22, green: 0.40, blue: 0.82),
                secondary: Color(red: 0.23, green: 0.63, blue: 0.73),
                glow: Color(red: 0.88, green: 0.93, blue: 1.0)
            )
        ),
        OnboardingPage(
            stepKey: "Onboarding Offline Step",
            titleKey: "Onboarding Offline Title",
            descriptionKey: "Onboarding Offline Body",
            highlightKeys: [
                "Onboarding Offline Highlight 1",
                "Onboarding Offline Highlight 2",
                "Onboarding Offline Highlight 3"
            ],
            chipKeys: [
                "Onboarding Offline Chip 1",
                "Onboarding Offline Chip 2",
                "Onboarding Offline Chip 3"
            ],
            routeTitleKey: "Onboarding Offline Route Title",
            routeValueKey: "Onboarding Offline Route Value",
            noteTitleKey: "Onboarding Offline Note Title",
            noteBodyKey: "Onboarding Offline Note Body",
            preview: .offline,
            palette: OnboardingPalette(
                primary: Color(red: 0.92, green: 0.47, blue: 0.20),
                secondary: Color(red: 0.13, green: 0.63, blue: 0.66),
                glow: Color(red: 1.0, green: 0.94, blue: 0.86)
            )
        ),
        OnboardingPage(
            stepKey: "Onboarding Gesture Step",
            titleKey: "Onboarding Gesture Title",
            descriptionKey: "Onboarding Gesture Body",
            highlightKeys: [
                "Onboarding Gesture Highlight 1",
                "Onboarding Gesture Highlight 2",
                "Onboarding Gesture Highlight 3"
            ],
            chipKeys: [
                "Onboarding Gesture Chip 1",
                "Onboarding Gesture Chip 2",
                "Onboarding Gesture Chip 3"
            ],
            routeTitleKey: "Onboarding Gesture Route Title",
            routeValueKey: "Onboarding Gesture Route Value",
            noteTitleKey: "Onboarding Gesture Note Title",
            noteBodyKey: "Onboarding Gesture Note Body",
            preview: .playback,
            palette: OnboardingPalette(
                primary: Color(red: 0.87, green: 0.28, blue: 0.33),
                secondary: Color(red: 0.15, green: 0.46, blue: 0.80),
                glow: Color(red: 1.0, green: 0.90, blue: 0.90)
            )
        )
    ]

    var body: some View {
        GeometryReader { geometry in
            let layout = OnboardingContainerLayout(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets)
            ZStack {
                onboardingBackground(for: currentPage)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                        .frame(maxWidth: layout.headerMaxWidth, alignment: .leading)
                        .padding(.horizontal, layout.horizontalPadding)
                        .padding(.top, layout.topPadding)
                        .padding(.bottom, layout.headerBottomPadding)

                    #if os(macOS)
                    ZStack {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                            if index == pageIndex {
                                OnboardingStageView(page: page, pageIndex: index, totalPages: pages.count)
                                    .padding(.horizontal, layout.horizontalPadding)
                                    .padding(.top, 0)
                                    .padding(.bottom, layout.stageBottomPadding)
                                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #else
                    TabView(selection: $pageIndex) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                            OnboardingStageView(page: page, pageIndex: index, totalPages: pages.count)
                                .padding(.horizontal, layout.horizontalPadding)
                                .padding(.top, 0)
                                .padding(.bottom, layout.stageBottomPadding)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    #endif

                    footer(layout: layout)
                        .frame(maxWidth: layout.footerMaxWidth)
                        .padding(.horizontal, layout.horizontalPadding)
                        .padding(.top, layout.footerTopPadding)
                        .padding(.bottom, layout.footerBottomPadding)
                }
            }
        }
    }

    private var currentPage: OnboardingPage {
        pages[pageIndex]
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(platformShellString("Onboarding Guide Eyebrow"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(headerSecondaryColor)
                    .tracking(0.3)

                Text(platformShellString(currentPage.stepKey))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(headerPrimaryColor)
                    .lineLimit(2)
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 10) {
                Button(action: finish) {
                    Text(platformShellString("Skip"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(skipButtonForegroundColor)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(skipButtonBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(skipButtonBorderColor, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 12, x: 0, y: 6)
                        .cornerRadius(18)
                }

                Text("\(pageIndex + 1)/\(pages.count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(headerSecondaryColor)
            }
        }
    }

    private func footer(layout: OnboardingContainerLayout) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            pageIndex = index
                        }
                    }) {
                        Capsule()
                            .fill(index == pageIndex ? currentPage.palette.primary : footerInactiveColor)
                            .frame(width: index == pageIndex ? 28 : 10, height: 7)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Spacer()

                Text(platformShellString(currentPage.routeValueKey))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(footerCaptionColor)
                    .lineLimit(layout.footerCaptionLineLimit)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if pageIndex > 0 {
                    Button(action: goBack) {
                        Text(platformShellString("Back"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(headerPrimaryColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(footerSecondaryButtonBackground)
                            .cornerRadius(16)
                    }
                }

                Button(action: goNextOrFinish) {
                    Text(pageIndex == pages.count - 1
                         ? platformShellString("Start Using Gen Player")
                         : platformShellString("Next"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    currentPage.palette.primary,
                                    currentPage.palette.secondary
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                        .shadow(color: currentPage.palette.primary.opacity(colorScheme == .dark ? 0.26 : 0.18), radius: 12, x: 0, y: 8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(footerBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(footerBorderColor, lineWidth: 1)
        )
        .shadow(color: footerShadowColor, radius: 18, x: 0, y: 12)
        .cornerRadius(24)
    }

    private func onboardingBackground(for page: OnboardingPage) -> some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: backgroundGradientColors(for: page)),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Rectangle()
                .fill(backgroundBaseOverlayColor)

            Circle()
                .fill(page.palette.primary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                .frame(width: 320, height: 320)
                .offset(x: 120, y: -240)
                .blur(radius: 16)

            Circle()
                .fill(page.palette.secondary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .frame(width: 360, height: 360)
                .offset(x: -160, y: 260)
                .blur(radius: 24)
        }
    }

    private func backgroundGradientColors(for page: OnboardingPage) -> [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.04, green: 0.06, blue: 0.10),
                page.palette.primary.opacity(0.22),
                Color(red: 0.03, green: 0.10, blue: 0.16)
            ]
        }

        return [
            Color.white,
            page.palette.glow,
            Color(red: 0.96, green: 0.98, blue: 1.0)
        ]
    }

    private var headerPrimaryColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.08, green: 0.19, blue: 0.30)
    }

    private var headerSecondaryColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.70) : Color(red: 0.25, green: 0.37, blue: 0.55)
    }

    private var skipButtonBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.17, green: 0.24, blue: 0.36).opacity(0.92)
            : Color(red: 0.96, green: 0.975, blue: 1.0)
    }

    private var skipButtonBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(red: 0.74, green: 0.82, blue: 0.92)
    }

    private var skipButtonForegroundColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.13, green: 0.24, blue: 0.39)
    }

    private var footerBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.94)
            : Color(red: 0.975, green: 0.985, blue: 1.0)
    }

    private var footerBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(red: 0.84, green: 0.89, blue: 0.96)
    }

    private var footerSecondaryButtonBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 0.93, green: 0.96, blue: 0.99)
    }

    private var footerInactiveColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.20) : Color(red: 0.74, green: 0.81, blue: 0.90)
    }

    private var footerCaptionColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.70) : Color(red: 0.29, green: 0.42, blue: 0.58)
    }

    private var footerShadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.26)
            : Color(red: 0.30, green: 0.43, blue: 0.60).opacity(0.10)
    }

    private var backgroundBaseOverlayColor: Color {
        colorScheme == .dark
            ? Color(red: 0.03, green: 0.05, blue: 0.09).opacity(0.76)
            : Color(red: 0.965, green: 0.98, blue: 1.0).opacity(0.92)
    }

    private func goBack() {
        guard pageIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            pageIndex -= 1
        }
    }

    private func goNextOrFinish() {
        if pageIndex < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.25)) {
                pageIndex += 1
            }
        } else {
            finish()
        }
    }

    private func finish() {
        onClose()
    }
}

private struct OnboardingContainerLayout {
    let size: CGSize
    let safeAreaInsets: EdgeInsets

    var isRegularWidth: Bool {
        size.width >= 768
    }

    var horizontalPadding: CGFloat {
        isRegularWidth ? 24 : 18
    }

    var headerMaxWidth: CGFloat {
        min(size.width - (horizontalPadding * 2), isRegularWidth ? 1100 : 760)
    }

    var footerMaxWidth: CGFloat {
        min(size.width - (horizontalPadding * 2), isRegularWidth ? 960 : 760)
    }

    var topPadding: CGFloat {
        max(safeAreaInsets.top - 18, isRegularWidth ? 22 : 18)
    }

    var headerBottomPadding: CGFloat {
        isRegularWidth ? 10 : 4
    }

    var stageBottomPadding: CGFloat {
        isRegularWidth ? 14 : 10
    }

    var footerTopPadding: CGFloat {
        isRegularWidth ? 12 : 8
    }

    var footerBottomPadding: CGFloat {
        max(safeAreaInsets.bottom, isRegularWidth ? 20 : 14)
    }

    var footerCaptionLineLimit: Int {
        size.width < 430 ? 2 : 1
    }
}

private struct OnboardingStageView: View {
    @Environment(\.colorScheme) private var colorScheme

    let page: OnboardingPage
    let pageIndex: Int
    let totalPages: Int

    var body: some View {
        GeometryReader { geometry in
            let layout = OnboardingStageLayout(size: geometry.size)
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if layout.usesWideLayout {
                        HStack(alignment: .top, spacing: layout.columnSpacing) {
                            previewCard
                                .frame(width: layout.previewColumnWidth)
                                .frame(minHeight: layout.wideCardMinHeight, alignment: .top)

                            detailCard
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: layout.wideCardMinHeight, alignment: .top)
                        }
                    } else {
                        VStack(spacing: layout.columnSpacing) {
                            previewCard
                            detailCard
                        }
                    }
                }
                .frame(maxWidth: layout.contentMaxWidth, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(minHeight: layout.stageMinHeight, alignment: .top)
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(pageIndex + 1)/\(totalPages)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(page.palette.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(page.palette.primary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .cornerRadius(999)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text(platformShellString(page.stepKey))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.82) : Color(red: 0.25, green: 0.38, blue: 0.54))
            }

            OnboardingPreview(page: page)

            Spacer(minLength: 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(page.chipKeys, id: \.self) { key in
                        OnboardingFeatureChip(
                            text: platformShellString(key),
                            tint: page.palette.primary,
                            colorScheme: colorScheme
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(18)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .shadow(color: cardShadowColor, radius: 22, x: 0, y: 14)
        .cornerRadius(28)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(platformShellString(page.titleKey))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(platformShellString(page.descriptionKey))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(secondaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.highlightKeys, id: \.self) { key in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(page.palette.primary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                                .frame(width: 24, height: 24)
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(page.palette.primary)
                        }

                        Text(platformShellString(key))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)

            OnboardingInfoCard(
                icon: "location.fill",
                title: platformShellString(page.routeTitleKey),
                message: platformShellString(page.routeValueKey),
                accent: page.palette.secondary,
                colorScheme: colorScheme
            )

            OnboardingInfoCard(
                icon: "flag.fill",
                title: platformShellString(page.noteTitleKey),
                message: platformShellString(page.noteBodyKey),
                accent: page.palette.primary,
                colorScheme: colorScheme
            )
        }
        .padding(22)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .shadow(color: cardShadowColor, radius: 22, x: 0, y: 14)
        .cornerRadius(28)
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.14, blue: 0.21).opacity(0.94)
            : Color(red: 0.975, green: 0.985, blue: 1.0)
    }

    private var cardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(red: 0.84, green: 0.89, blue: 0.96)
    }

    private var cardShadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.26)
            : Color(red: 0.30, green: 0.43, blue: 0.60).opacity(0.10)
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : Color(red: 0.08, green: 0.18, blue: 0.29)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : Color(red: 0.27, green: 0.38, blue: 0.54)
    }
}

private struct OnboardingStageLayout {
    let size: CGSize

    var usesWideLayout: Bool {
        size.width > 760
    }

    var columnSpacing: CGFloat {
        usesWideLayout ? 20 : 18
    }

    var contentMaxWidth: CGFloat {
        min(size.width, usesWideLayout ? 1120 : 760)
    }

    var previewColumnWidth: CGFloat {
        min(max(size.width * 0.46, 360), 540)
    }

    var wideCardMinHeight: CGFloat {
        min(max(size.height * 0.52, 500), 640)
    }

    var stageMinHeight: CGFloat {
        usesWideLayout ? max(size.height - 12, wideCardMinHeight) : max(size.height - 12, 0)
    }
}

private struct OnboardingPreview: View {
    let page: OnboardingPage

    var body: some View {
        Group {
            switch page.preview {
            case .hub:
                OnboardingMediaHubPreview(page: page)
            case .sources:
                OnboardingSourcePreview(page: page)
            case .privacy:
                OnboardingPrivacyPreview(page: page)
            case .offline:
                OnboardingOfflinePreview(page: page)
            case .playback:
                OnboardingPlaybackPreview(page: page)
            }
        }
    }
}

private struct OnboardingMediaHubPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                previewTab(platformShellString("Local"), active: true)
                previewTab(platformShellString("Network"), active: false)
                previewTab(platformShellString("My"), active: false)
                Spacer()
            }

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                page.palette.primary.opacity(0.95),
                                page.palette.secondary.opacity(0.92)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 210)
                    .overlay(
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 20))
                                Text(platformShellString("Continue Watching"))
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)

                            Spacer()

                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.22))
                                .frame(width: 120, height: 10)

                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .frame(height: 8)

                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 150, height: 8)

                            HStack(spacing: 8) {
                                capsuleLabel(platformShellString("View Details"))
                                capsuleLabel(platformShellString("Downloads"))
                            }
                        }
                        .padding(16)
                    )

                VStack(spacing: 12) {
                    sideActionCard(icon: "clock.arrow.circlepath", title: platformShellString("Continue Watching"))
                    sideActionCard(icon: "star.fill", title: platformShellString("Favorites"))
                    sideActionCard(icon: "rectangle.stack.fill", title: platformShellString("View Details"))
                }
                .frame(width: 122)
            }

            HStack(spacing: 10) {
                metricCard(icon: "folder.fill", title: platformShellString("Local"), value: "120")
                metricCard(icon: "network", title: platformShellString("Network"), value: "8")
                metricCard(icon: "arrow.down.circle.fill", title: platformShellString("Downloads"), value: "24")
            }
        }
    }

    private func previewTab(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(active ? .white : secondaryForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? activeBackground : inactiveBackground)
            .cornerRadius(999)
    }

    private var activeBackground: Color {
        page.palette.primary
    }

    private var inactiveBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.70)
    }

    private var secondaryForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : Color(red: 0.29, green: 0.40, blue: 0.56)
    }

    private func capsuleLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.18))
            .cornerRadius(999)
    }

    private func sideActionCard(icon: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(page.palette.primary)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(lineColor)
                .frame(height: 8)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(secondaryForeground)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .cornerRadius(18)
    }

    private func metricCard(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(page.palette.primary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(primaryForeground)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(secondaryForeground)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .cornerRadius(18)
    }

    private var tileBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.92)
            : Color(red: 0.985, green: 0.992, blue: 1.0)
    }

    private var lineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color(red: 0.84, green: 0.89, blue: 0.95)
    }

    private var primaryForeground: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.18, blue: 0.28)
    }
}

private struct OnboardingSourcePreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let page: OnboardingPage

    private let protocols = ["SMB", "WebDAV", "Jellyfin", "Emby", "Plex", "FTP", "SFTP", "NFS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(platformShellString("Add Server"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(primaryForeground)

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(lineColor)
                        .frame(width: 170, height: 8)
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(page.palette.primary.opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(page.palette.primary)
                }
            }
            .padding(16)
            .background(tileBackground)
            .cornerRadius(22)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(page.palette.secondary)
                    Text(platformShellString("Onboarding Source Chip 1"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryForeground)
                    Spacer()
                }

                HStack(spacing: 8) {
                    ForEach(protocols.prefix(4), id: \.self) { item in
                        protocolPill(item)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(protocols.suffix(4), id: \.self) { item in
                        protocolPill(item)
                    }
                }
            }
            .padding(16)
            .background(tileBackground)
            .cornerRadius(22)

            HStack(spacing: 12) {
                infoStat(icon: "lock.fill", title: platformShellString("Security"))
                infoStat(icon: "sparkles.rectangle.stack", title: platformShellString("Onboarding Source Chip 2"))
            }
        }
    }

    private func protocolPill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(primaryForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                colorScheme == .dark
                    ? Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.92)
                    : Color(red: 0.985, green: 0.992, blue: 1.0)
            )
            .cornerRadius(999)
    }

    private func infoStat(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(page.palette.primary.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(page.palette.primary)
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primaryForeground)
                .lineLimit(2)

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .cornerRadius(20)
    }

    private var tileBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.92)
            : Color(red: 0.985, green: 0.992, blue: 1.0)
    }

    private var lineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color(red: 0.84, green: 0.89, blue: 0.95)
    }

    private var primaryForeground: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.18, blue: 0.28)
    }
}

private struct OnboardingOfflinePreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let page: OnboardingPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(platformShellString("Downloads"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(primaryForeground)
                Spacer()
                Text("3")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(page.palette.primary)
            }
            .padding(16)
            .background(tileBackground)
            .cornerRadius(22)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    statusDot(page.palette.primary)
                    Text(platformShellString("Onboarding Offline Chip 1"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryForeground)
                    Spacer()
                    Text("68%")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(page.palette.primary)
                }

                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(progressTrack)
                    .frame(height: 10)
                    .overlay(
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 999, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [page.palette.primary, page.palette.secondary]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * 0.68)
                        }
                    )
            }
            .padding(16)
            .background(tileBackground)
            .cornerRadius(22)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        statusDot(page.palette.secondary)
                        Text(platformShellString("Offline Available"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(primaryForeground)
                    }

                    Text(platformShellString("Show in Folder"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(secondaryForeground)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tileBackground)
                .cornerRadius(20)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        statusDot(Color(red: 0.82, green: 0.52, blue: 0.20))
                        Text(platformShellString("Not Downloaded"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(primaryForeground)
                    }

                    Text(platformShellString("Onboarding Offline Chip 3"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(secondaryForeground)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tileBackground)
                .cornerRadius(20)
            }
        }
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var tileBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.92)
            : Color(red: 0.985, green: 0.992, blue: 1.0)
    }

    private var progressTrack: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(red: 0.85, green: 0.89, blue: 0.94)
    }

    private var primaryForeground: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.18, blue: 0.28)
    }

    private var secondaryForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.70) : Color(red: 0.29, green: 0.40, blue: 0.56)
    }
}

private struct OnboardingPrivacyPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let page: OnboardingPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(platformShellString("Privacy Space"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(primaryForeground)

                    Text(platformShellString("Onboarding Privacy Chip 1"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(secondaryForeground)
                }

                Spacer()

                Text(platformShellString("On"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(page.palette.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(page.palette.primary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .cornerRadius(999)
            }
            .padding(16)
            .background(tileBackground)
            .cornerRadius(22)

            HStack(spacing: 12) {
                privacyOptionTile(
                    icon: "faceid",
                    title: platformShellString("Use Biometrics for Privacy Space")
                )

                privacyOptionTile(
                    icon: "eye.slash.fill",
                    title: platformShellString("Hide Locked Items")
                )
            }

            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(page.palette.primary.opacity(0.14))
                            .frame(width: 38, height: 38)

                        Image(systemName: "clock.badge.xmark.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(page.palette.primary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(platformShellString("Exclude Private Content from History"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(primaryForeground)
                            .lineLimit(2)

                        Text(platformShellString("Onboarding Privacy Chip 3"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(secondaryForeground)
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tileBackground)
                .cornerRadius(20)
            }

        }
    }

    private func privacyOptionTile(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(page.palette.primary.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(page.palette.primary)
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primaryForeground)
                .lineLimit(2)

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .cornerRadius(20)
    }

    private var tileBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.92)
            : Color(red: 0.985, green: 0.992, blue: 1.0)
    }

    private var primaryForeground: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.18, blue: 0.28)
    }

    private var secondaryForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.70) : Color(red: 0.29, green: 0.40, blue: 0.56)
    }
}

private struct OnboardingPlaybackPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            page.palette.primary.opacity(0.96),
                            page.palette.secondary.opacity(0.94)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 220)
                .overlay(
                    ZStack {
                        HStack {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 22, weight: .bold))
                            Spacer()
                            Image(systemName: "goforward.10")
                                .font(.system(size: 22, weight: .bold))
                        }
                        .foregroundColor(Color.white.opacity(0.90))
                        .padding(.horizontal, 28)

                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 72, height: 72)

                        Image(systemName: "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)

                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                capsuleLabel(platformShellString("Playback Options"))
                                capsuleLabel(platformShellString("Favorites"))
                            }
                            .padding(.bottom, 18)
                        }
                    }
                )

            HStack(spacing: 12) {
                actionTile(icon: "captions.bubble.fill", title: platformShellString("Playback Options"))
                actionTile(icon: "clock.arrow.circlepath", title: platformShellString("Continue Watching"))
                actionTile(icon: "star.fill", title: platformShellString("Favorites"))
            }
        }
    }

    private func capsuleLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.18))
            .cornerRadius(999)
    }

    private func actionTile(icon: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(page.palette.primary)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(lineColor)
                .frame(height: 8)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(primaryForeground)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .cornerRadius(18)
    }

    private var tileBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.92)
            : Color(red: 0.985, green: 0.992, blue: 1.0)
    }

    private var lineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color(red: 0.84, green: 0.89, blue: 0.95)
    }

    private var primaryForeground: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.18, blue: 0.28)
    }
}

private struct OnboardingFeatureChip: View {
    let text: String
    let tint: Color
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.86) : Color(red: 0.19, green: 0.31, blue: 0.45))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(colorScheme == .dark ? Color.white.opacity(0.08) : tint.opacity(0.10))
        .cornerRadius(999)
    }
}

private struct OnboardingInfoCard: View {
    let icon: String
    let title: String
    let message: String
    let accent: Color
    let colorScheme: ColorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(colorScheme == .dark ? .white : Color(red: 0.10, green: 0.18, blue: 0.28))

                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.74) : Color(red: 0.29, green: 0.40, blue: 0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            colorScheme == .dark
                ? Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.90)
                : Color(red: 0.965, green: 0.982, blue: 1.0)
        )
        .cornerRadius(18)
    }
}

private struct OnboardingPalette {
    let primary: Color
    let secondary: Color
    let glow: Color
}

private struct OnboardingPage {
    let stepKey: String
    let titleKey: String
    let descriptionKey: String
    let highlightKeys: [String]
    let chipKeys: [String]
    let routeTitleKey: String
    let routeValueKey: String
    let noteTitleKey: String
    let noteBodyKey: String
    let preview: OnboardingPreviewKind
    let palette: OnboardingPalette
}

private enum OnboardingPreviewKind {
    case hub
    case sources
    case privacy
    case offline
    case playback
}


#if os(macOS)
private struct MacWelcomeView: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                        .frame(width: 80, height: 80)
                        .cornerRadius(16)
                        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                    
                    Text(platformShellString("Welcome to Gen Player"))
                        .font(.system(size: 32, weight: .bold))
                }
                .padding(.top, 40)
                
                VStack(alignment: .leading, spacing: 28) {
                    FeatureRow(
                        icon: "square.grid.2x2.fill",
                        color: .blue,
                        title: platformShellString("Onboarding Welcome Chip 1"),
                        description: platformShellString("Onboarding Welcome Highlight 1")
                    )
                    
                    FeatureRow(
                        icon: "clock.arrow.circlepath",
                        color: .purple,
                        title: platformShellString("Onboarding Welcome Chip 2"),
                        description: platformShellString("Onboarding Welcome Highlight 2")
                    )
                    
                    FeatureRow(
                        icon: "arrow.down.circle.fill",
                        color: .green,
                        title: platformShellString("Onboarding Offline Chip 1"),
                        description: platformShellString("Onboarding Offline Highlight 1")
                    )
                }
                .padding(.horizontal, 48)
                
                Spacer()
                
                Button(action: onClose) {
                    Text(platformShellString("Start Using Gen Player"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor)
                .cornerRadius(10)
                .padding(.horizontal, 48)
                .padding(.bottom, 40)
            }
            .frame(width: 480, height: 560)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.2), radius: 30, x: 0, y: 15)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(color)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                
                Text(description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
#endif
