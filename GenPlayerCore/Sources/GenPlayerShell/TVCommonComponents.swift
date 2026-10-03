#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVShelfSection<Content: View>: View {
    private static var leadingAnchorID: String { "TVShelfSectionLeadingAnchor" }

    let title: String
    let subtitle: String?
    let systemImage: String?
    let headerServer: ServerConfig?
    let headerAccessory: AnyView?
    let headerDestination: AnyView?
    /// Optional trailing card content placed at the end of the horizontal scroll area.
    let inlineAccessory: AnyView?
    let content: () -> Content

    init(
        title: String,
        subtitle: String?,
        systemImage: String? = nil,
        headerServer: ServerConfig? = nil,
        headerAccessory: AnyView? = nil,
        inlineAccessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.headerServer = headerServer
        self.headerAccessory = headerAccessory
        self.headerDestination = nil
        self.inlineAccessory = inlineAccessory
        self.content = content
    }

    init<Destination: View>(
        title: String,
        subtitle: String?,
        systemImage: String? = nil,
        headerDestination: Destination,
        inlineAccessory: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.headerServer = nil
        self.headerAccessory = nil
        self.headerDestination = AnyView(headerDestination)
        self.inlineAccessory = inlineAccessory
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 14) {
                header(scrollProxy: proxy)

                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id(Self.leadingAnchorID)

                        LazyHStack(alignment: .top, spacing: 40) {
                            content()

                            if let inlineAccessory {
                                inlineAccessory
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                    .padding(.vertical, 28)
                }
                .tvFocusSectionIfAvailable()
                .padding(.horizontal, -22)
            }
        }
    }

    @ViewBuilder
    func header(scrollProxy: ScrollViewProxy) -> some View {
        if let headerDestination {
            NavigationLink(destination: headerDestination) {
                HStack(spacing: 0) {
                    TVShelfSectionNavigationHeader(
                        title: title,
                        subtitle: subtitle,
                        systemImage: systemImage,
                        onFocusChange: { isFocused in
                            guard isFocused else { return }
                            DispatchQueue.main.async {
                                scrollProxy.scrollTo(Self.leadingAnchorID, anchor: .leading)
                            }
                        }
                    )

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .tvFocusSectionIfAvailable()
        } else {
            TVShelfSectionPlainHeader(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                server: headerServer,
                headerAccessory: headerAccessory
            )
        }
    }
}



struct TVShelfSectionPlainHeader: View {
    let title: String
    let subtitle: String?
    var systemImage: String? = nil
    let server: ServerConfig?
    let headerAccessory: AnyView?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            if let server {
                TVServerGroupHeader(server: server)
            } else {
                TVShelfGroupTitle(title: title, subtitle: subtitle, systemImage: systemImage)
            }

            if let headerAccessory {
                headerAccessory
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }
}



struct TVShelfGroupTitle: View {
    let title: String
    let subtitle: String?
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                if let systemImage, !systemImage.isEmpty {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(TVShellStyle.primary.opacity(0.88))
                }

                Text(title)
                    .font(.system(size: 36, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
        }
    }
}



struct TVServerGroupHeader: View {
    let server: ServerConfig

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TVServerTypeLogo(type: server.type, size: 38, showsBackground: false)

            Text(server.name)
                .font(.system(size: 38, weight: .heavy))
                .foregroundColor(TVShellStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .accessibilityElement(children: .combine)
    }
}



struct TVRemoteBrowserServerIdentityHeader: View {
    let server: ServerConfig

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            TVServerTypeLogo(type: server.type, size: 76, showsBackground: true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(server.type.displayName)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(server.type.tvAccentColor)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(
                            Capsule(style: .continuous)
                                .fill(server.type.tvAccentColor.opacity(0.16))
                        )

                    Text(tvServerSummary(for: server))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }

                Text(server.name)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            server.type.tvAccentColor.opacity(0.16),
                            Color.white.opacity(0.060),
                            Color.black.opacity(0.16)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}





struct TVRemoteBrowserHeaderControls: View {
    @Binding var sortOptionRaw: String
    @Binding var isAscending: Bool
    @Binding var showsFoldersOnTop: Bool
    @Binding var isGridLayout: Bool
    var showsFileControls: Bool
    var showsHomeAction: Bool
    var onRefresh: (() -> Void)? = nil
    let onHome: () -> Void
    let onDownloads: () -> Void
    var onClose: (() -> Void)? = nil

    @State private var focusedHeaderAction: TVHeaderActionFocus?
    // Local @State mirrors — Menu content reads these so SwiftUI can
    // re-evaluate checkmarks after selection (same pattern as Jellyfin's @State sortField).
    @State private var localSortOption: TVFileSortOption = .name
    @State private var localIsAscending: Bool = true
    @State private var localShowsFoldersOnTop: Bool = true

    private var layoutTitle: String {
        platformShellString(isGridLayout ? "List" : "Grid")
    }

    private var layoutSystemImageName: String {
        isGridLayout ? "list.bullet" : "square.grid.2x2"
    }

    private var sortSummaryTitle: String {
        "\(localSortOption.title) · \(platformShellString(localIsAscending ? "Ascending" : "Descending"))"
    }

    private func selectSortOption(_ option: TVFileSortOption) {
        guard localSortOption != option else { return }
        localSortOption = option
        localIsAscending = option == .name
        // sync back to @Binding / @AppStorage
        sortOptionRaw = option.rawValue
        isAscending = option == .name
    }

    var body: some View {
        HStack(spacing: 14) {
            TVHeaderActionDescriptionText(
                text: focusedHeaderAction?.title,
                width: 280,
                isDestructive: false,
                alignment: .trailing
            )

            if showsFileControls {
                // 1st: Layout Toggle Button
                Button(action: { isGridLayout.toggle() }) {
                    TVTopChromeIconButton(
                        title: layoutTitle,
                        systemImageName: layoutSystemImageName,
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "layout", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            if showsFileControls {
                // 2nd: Sort Button
                NavigationLink(
                    destination: TVRemoteBrowserSortView(
                        sortOptionRaw: $sortOptionRaw,
                        isAscending: $isAscending,
                        showsFoldersOnTop: $showsFoldersOnTop
                    )
                ) {
                    TVTopChromeIconButton(
                        title: platformShellString("Sort"),
                        systemImageName: "line.3.horizontal.decrease.circle",
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "sort", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            if let onRefresh {
                // 3rd: Refresh Button
                Button(action: {
                    focusedHeaderAction = nil
                    onRefresh()
                }) {
                    TVTopChromeIconButton(
                        title: platformShellString("Refresh"),
                        systemImageName: "arrow.clockwise",
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "refresh", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            // 4th: Downloads Button
            TVDownloadsTopChromeButton(
                diameter: 66,
                onFocusChange: { title, isFocused in
                    updateFocus(id: "downloads", title: title, isFocused: isFocused)
                },
                action: {
                    focusedHeaderAction = nil
                    onDownloads()
                }
            )

            // 5th: Home Button
            if showsHomeAction {
                Button(action: {
                    focusedHeaderAction = nil
                    onHome()
                }) {
                    TVTopChromeIconButton(
                        title: platformShellString("Home"),
                        systemImageName: "house",
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "home", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            // 6th: Close Button
            if let onClose {
                Button(action: {
                    focusedHeaderAction = nil
                    onClose()
                }) {
                    TVTopChromeIconButton(
                        title: platformShellString("Close"),
                        systemImageName: "rectangle.portrait.and.arrow.right",
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "close", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
        .tvFocusSectionIfAvailable()
        .onAppear {
            // Initialise local mirrors from persisted bindings
            localSortOption = TVFileSortOption(rawValue: sortOptionRaw) ?? .name
            localIsAscending = isAscending
            localShowsFoldersOnTop = showsFoldersOnTop
        }
        // Keep local mirrors in sync if the parent changes the binding externally
        .onChange(of: sortOptionRaw) { newValue in
            let parsed = TVFileSortOption(rawValue: newValue) ?? .name
            if localSortOption != parsed { localSortOption = parsed }
        }
        .onChange(of: isAscending) { newValue in
            if localIsAscending != newValue { localIsAscending = newValue }
        }
        .onChange(of: showsFoldersOnTop) { newValue in
            if localShowsFoldersOnTop != newValue { localShowsFoldersOnTop = newValue }
        }
    }

    private func updateFocus(id: String, title: String, isFocused: Bool) {
        if isFocused {
            focusedHeaderAction = TVHeaderActionFocus(id: id, title: title, isDestructive: false)
        } else if focusedHeaderAction?.id == id {
            focusedHeaderAction = nil
        }
    }
}



struct TVShelfSectionNavigationHeader: View {
    let title: String
    let subtitle: String?
    var systemImage: String? = nil
    let onFocusChange: (Bool) -> Void

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let systemImage, !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .font(.system(size: showsFocus ? 30 : 26, weight: .bold))
                    .foregroundColor(titleColor.opacity(0.92))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: showsFocus ? 31 : 28, weight: .heavy))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                HStack(spacing: 6) {
                    Text(detailText)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .heavy))
                }
                .foregroundColor(detailColor)
                .opacity(detailOpacity)
            }
        }
        .padding(.leading, showsFocus ? 22 : 0)
        .padding(.trailing, showsFocus ? 24 : 0)
        .padding(.vertical, 10)
        .frame(minHeight: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            TVFocusedBlockOverlay(cornerRadius: 25, showsFocus: showsFocus, outerLineWidth: 2.4, innerInset: 3)
        )
        .overlay(
            Capsule(style: .continuous)
                .fill(TVShellStyle.accentSoft)
                .frame(width: 5, height: 50)
                .padding(.leading, 9)
                .opacity(showsFocus ? 1 : 0),
            alignment: .leading
        )
        .shadow(color: showsFocus ? Color.black.opacity(0.22) : .clear, radius: showsFocus ? 16 : 0, x: 0, y: showsFocus ? 8 : 0)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .modifier(TVFocusedCardLayerModifier())
        .onChange(of: isFocused) { focused in
            onFocusChange(focused && isEnabled)
        }
    }

    private var detailText: String {
        guard let subtitle, !subtitle.isEmpty else {
            return platformShellString("View All")
        }
        return subtitle
    }

    private var titleColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.45) }
        return TVShellStyle.primary.opacity(showsFocus ? 1.0 : 0.94)
    }

    private var detailColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.38) }
        return showsFocus ? TVShellStyle.accentSoft : TVShellStyle.secondary
    }

    private var detailOpacity: Double {
        if subtitle != nil {
            return showsFocus ? 0.88 : 0.66
        }
        return showsFocus ? 0.84 : 0.54
    }

    private var backgroundFill: Color {
        guard showsFocus else { return Color.clear }
        return Color.white.opacity(colorScheme == .dark ? 0.13 : 0.72)
    }
}



struct TVPageScrollView<Content: View>: View {
    @Environment(\.tvBrowsingNavigation) private var browsingNavigation
    @Environment(\.presentationMode) private var presentationMode
    let title: String
    let subtitle: String?
    let handlesExitCommand: Bool
    let customExitCommand: (() -> Bool)?
    let showsTitle: Bool
    let titleAccessory: AnyView?
    let topChromeAccessory: AnyView?
    let topPadding: CGFloat?
    let scrollTargetID: String?
    let showsHomeAction: Bool
    let customHomeAction: (() -> Void)?
    let showsDownloadsAction: Bool
    let content: () -> Content
    @State private var isShowingDownloads = false

    init(
        title: String,
        subtitle: String?,
        handlesExitCommand: Bool = false,
        customExitCommand: (() -> Bool)? = nil,
        showsTitle: Bool = true,
        titleAccessory: AnyView? = nil,
        topChromeAccessory: AnyView? = nil,
        topPadding: CGFloat? = nil,
        scrollTargetID: String? = nil,
        showsHomeAction: Bool = false,
        customHomeAction: (() -> Void)? = nil,
        showsDownloadsAction: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.handlesExitCommand = handlesExitCommand
        self.customExitCommand = customExitCommand
        self.showsTitle = showsTitle
        self.titleAccessory = titleAccessory
        self.topChromeAccessory = topChromeAccessory
        self.topPadding = topPadding
        self.scrollTargetID = scrollTargetID
        self.showsHomeAction = showsHomeAction
        self.customHomeAction = customHomeAction
        self.showsDownloadsAction = showsDownloadsAction
        self.content = content
    }

    private var baseContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if showsTitle {
                        HStack(alignment: .center, spacing: 24) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(title)
                                    .font(.system(size: 42, weight: .bold))
                                    .foregroundColor(TVShellStyle.primary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.72)

                                if let subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.headline.weight(.medium))
                                        .foregroundColor(TVShellStyle.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 24)

                            if let titleAccessory {
                                titleAccessory
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tvFocusSectionIfAvailable()
                    }

                    content()
                }
                .padding(.horizontal, TVPageContentMetrics.horizontalPadding)
                .padding(.top, topPadding ?? (showsTitle ? 42 : 30))
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                scrollToTarget(using: proxy, animated: false)
            }
            .onChange(of: scrollTargetID ?? "") { _ in
                scrollToTarget(using: proxy, animated: false)
            }
        }
        .background(TVCinematicBackground())
        .navigationBarHidden(true)
        .overlay(topChromeActionOverlay, alignment: .top)
        .background(downloadsNavigationLink)
    }

    private var topChromeActionOverlay: some View {
        Group {
            if showsHomeAction || showsDownloadsAction || topChromeAccessory != nil {
                HStack(spacing: 14) {
                    Spacer(minLength: 0)

                    if let topChromeAccessory {
                        topChromeAccessory
                    }

                    if showsDownloadsAction {
                        TVDownloadsTopChromeButton {
                            isShowingDownloads = true
                        }
                    }

                    if showsHomeAction {
                        Button(action: returnToHome) {
                            TVTopChromeIconButton(
                                title: platformShellString("Home"),
                                systemImageName: "house"
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
                .padding(.top, 34)
                .padding(.trailing, TVPageContentMetrics.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .tvFocusSectionIfAvailable()
            }
        }
    }

    private var downloadsNavigationLink: some View {
        Group {
            if showsDownloadsAction {
                NavigationLink(
                    destination: TVDownloadsDetailView(),
                    isActive: $isShowingDownloads
                ) {
                    EmptyView()
                }
                .hidden()
            }
        }
    }

    var body: some View {
        Group {
            if handlesExitCommand {
                baseContent
                    .onExitCommand(perform: handleExitCommand)
            } else {
                baseContent
            }
        }
    }

    func handleExitCommand() {
        if TVPlaybackCoordinator.shared.shouldSuppressExitCommands() {
            traceNavigationExit("suppressed-for-playback")
            return
        }

        if let browsingNavigation {
            browsingNavigation.back(custom: customExitCommand)
            return
        }

        if customExitCommand?() == true {
            traceNavigationExit("custom-page-back")
            return
        }

        if tvPopNavigationIfPossible(in: browsingNavigation) {
            traceNavigationExit("pop-page")
            return
        }

        traceNavigationExit("dismiss-root")
        presentationMode.wrappedValue.dismiss()
    }

    private func traceNavigationExit(_ action: String) {
        #if DEBUG
        // Do not log server names, paths or credentials.
        NSLog("[TVNavigationExit] %@", action)
        #endif
    }

    private func returnToHome() {
        if TVPlaybackCoordinator.shared.shouldSuppressExitCommands() {
            return
        }

        if let customHomeAction {
            customHomeAction()
            return
        }

        if tvPopToRootNavigationIfPossible(in: browsingNavigation) {
            return
        }

        if let browsingNavigation {
            browsingNavigation.onExit()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private func scrollToTarget(using proxy: ScrollViewProxy, animated: Bool) {
        guard let scrollTargetID, !scrollTargetID.isEmpty else { return }
        for delay in [0.02, 0.12, 0.25, 0.50] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if animated {
                    withAnimation(.easeOut(duration: 0.20)) {
                        proxy.scrollTo(scrollTargetID, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(scrollTargetID, anchor: .center)
                }
            }
        }
    }
}



struct TVFullBleedHeroRow<Content: View>: View {
    let height: CGFloat
    let content: () -> Content

    init(height: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.height = height
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let paddedWidth = proxy.size.width + TVPageContentMetrics.horizontalPadding * 2
            let fullBleedWidth = max(paddedWidth, UIScreen.main.bounds.width)
            let pagePaddingOffset = -TVPageContentMetrics.horizontalPadding
            let screenEdgeOffset = -proxy.frame(in: .global).minX
            let horizontalOffset = min(pagePaddingOffset, screenEdgeOffset)

            content()
                .frame(
                    width: fullBleedWidth,
                    height: height
                )
                .offset(x: horizontalOffset)
        }
        .frame(height: height)
        .ignoresSafeArea(.container, edges: .horizontal)
    }
}



struct TVFeedbackPanelAction {
    let title: String
    let systemImageName: String
    var isEnabled = true
    let action: () -> Void
}



enum TVFeedbackPanelKind {
    case info
    case empty
    case warning
    case error

    var defaultTintColor: Color {
        switch self {
        case .info:
            return TVShellStyle.accentSoft
        case .empty:
            return TVShellStyle.secondary
        case .warning:
            return Color(red: 1.0, green: 0.72, blue: 0.28)
        case .error:
            return Color(red: 1.0, green: 0.36, blue: 0.40)
        }
    }
}



struct TVFeedbackPanel: View {
    let title: String
    let message: String
    let systemImageName: String
    var kind: TVFeedbackPanelKind = .info
    var tintColor: Color?
    var action: TVFeedbackPanelAction?

    private var resolvedTintColor: Color {
        tintColor ?? kind.defaultTintColor
    }

    var panelContent: some View {
        VStack(alignment: .leading, spacing: action == nil ? 0 : 22) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(resolvedTintColor.opacity(kind == .error ? 0.18 : 0.14))

                    Image(systemName: systemImageName)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(resolvedTintColor)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    Text(message)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 860, alignment: .leading)
                }
            }

            if let action {
                Button(action: action.action) {
                    TVFeedbackActionButtonLabel(
                        title: action.title,
                        systemImageName: action.systemImageName,
                        tintColor: resolvedTintColor
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
                .disabled(!action.isEnabled)
            }
        }
    }

    var body: some View {
        if action == nil {
            TVFocusableStaticPanel {
                panelContent
                    .tvDetailPanel()
            }
        } else {
            panelContent
                .tvDetailPanel()
        }
    }
}



struct TVFeedbackActionButtonLabel: View {
    let title: String
    let systemImageName: String
    let tintColor: Color

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var foregroundColor: Color {
        if !isEnabled { return TVShellStyle.secondary.opacity(0.45) }
        return showsFocus ? Color.black.opacity(0.88) : TVShellStyle.primary
    }

    private var fillColor: Color {
        if !isEnabled { return TVShellStyle.subtleFill.opacity(0.45) }
        return showsFocus ? Color.white.opacity(0.94) : tintColor.opacity(0.16)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImageName)
                .font(.system(size: 20, weight: .heavy))

            Text(title)
                .font(.system(size: 22, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 22)
        .frame(minWidth: 190, minHeight: 58)
        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(showsFocus ? Color.clear : tintColor.opacity(0.36), lineWidth: 1.2)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: 17, showsFocus: showsFocus, outerLineWidth: 2.8, innerInset: 3))
        .scaleEffect(showsFocus ? 1.016 : 1.0)
        .shadow(color: showsFocus ? Color.black.opacity(0.18) : .clear, radius: showsFocus ? 10 : 0, x: 0, y: showsFocus ? 5 : 0)
        .modifier(TVFocusedCardLayerModifier())
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .tvDisableSystemFocusEffect()
    }
}



struct TVEmptyStateCard: View {
    let title: String
    let message: String
    let systemImageName: String

    var body: some View {
        TVFeedbackPanel(
            title: title,
            message: message,
            systemImageName: systemImageName,
            kind: .empty
        )
    }
}



struct TVProfileEmptyPreviewCard: View {
    let title: String
    let message: String
    let systemImageName: String

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

    private var iconFillColor: Color {
        showsFocus ? Color.black.opacity(0.10) : TVShellStyle.accentSoft.opacity(0.14)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(iconFillColor)

                Image(systemName: systemImageName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(showsFocus ? Color.black.opacity(0.84) : TVShellStyle.accentSoft)
            }
            .frame(width: TVProfilePreviewCardMetrics.iconSize, height: TVProfilePreviewCardMetrics.iconSize)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(message)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(secondaryColor)
        }
        .padding(.horizontal, TVProfilePreviewCardMetrics.horizontalPadding)
        .frame(
            width: TVProfilePreviewCardMetrics.width,
            height: TVProfilePreviewCardMetrics.height,
            alignment: .leading
        )
        .contentShape(RoundedRectangle(cornerRadius: TVProfilePreviewCardMetrics.cornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: TVProfilePreviewCardMetrics.cornerRadius, style: .continuous)
                .fill(showsFocus ? TVRowFocusStyle.focusedFill(for: colorScheme) : TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TVProfilePreviewCardMetrics.cornerRadius, style: .continuous)
                .stroke(showsFocus ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: TVProfilePreviewCardMetrics.cornerRadius, showsFocus: showsFocus, outerLineWidth: 3.2, innerInset: 3))
        .scaleEffect(showsFocus ? 1.024 : 1.0)
        .shadow(color: showsFocus ? Color.black.opacity(0.24) : .clear, radius: showsFocus ? 18 : 0, x: 0, y: showsFocus ? 10 : 0)
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .modifier(TVFocusedCardLayerModifier())
    }
}



struct TVLoadingCard: View {
    var body: some View {
        TVFocusableStaticPanel {
            HStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text(platformShellString("Platform Shell TV Loading"))
                    .font(.headline)
            }
            .tvDetailPanel()
        }
    }
}



struct TVMetricCard: View {
    let title: String
    let value: String
    let systemImageName: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.10))

                Image(systemName: systemImageName)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(TVShellStyle.accentSoft)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(value)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(TVShellStyle.glassStroke, lineWidth: 1)
        )
    }
}



struct TVMetricsRow<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: 20, alignment: .top)],
            alignment: .leading,
            spacing: 20
        ) {
            content()
        }
    }
}



struct TVFocusableRowGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columnsPerRow: Int
    let columnWidth: CGFloat
    let rowMinHeight: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let content: (Item) -> Content

    init(
        items: [Item],
        columnsPerRow: Int,
        columnWidth: CGFloat,
        rowMinHeight: CGFloat,
        columnSpacing: CGFloat,
        rowSpacing: CGFloat,
        horizontalPadding: CGFloat = 0,
        verticalPadding: CGFloat = 0,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.columnsPerRow = max(columnsPerRow, 1)
        self.columnWidth = columnWidth
        self.rowMinHeight = rowMinHeight
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content
    }

    private struct RowWrapper: Identifiable {
        let id: String
        let items: [Item]
    }

    private var rows: [RowWrapper] {
        stride(from: 0, to: items.count, by: columnsPerRow).map { startIndex in
            let endIndex = min(startIndex + columnsPerRow, items.count)
            let chunk = Array(items[startIndex..<endIndex])
            let rowId = chunk.map { String(describing: $0.id) }.joined(separator: "-")
            return RowWrapper(id: rowId, items: chunk)
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(row.items) { item in
                        content(item)
                            .frame(width: columnWidth, alignment: .topLeading)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
                .tvFocusSectionIfAvailable()
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }
}



struct TVFileGridSection<Content: View>: View {
    let title: String?
    let subtitle: String?
    let itemType: VideoFile.FileType
    let items: [VideoFile]
    let content: (VideoFile) -> Content

    init(
        title: String?,
        subtitle: String?,
        itemType: VideoFile.FileType = .unknown,
        items: [VideoFile],
        @ViewBuilder content: @escaping (VideoFile) -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.itemType = itemType
        self.items = items
        self.content = content
    }

    private var columnsPerRow: Int {
        6
    }

    private var columnWidth: CGFloat {
        252
    }

    private var columnSpacing: CGFloat {
        20
    }

    private var rowSpacing: CGFloat {
        40
    }

    private var rowMinHeight: CGFloat {
        276
    }

    var body: some View {
        VStack(alignment: .leading, spacing: title == nil ? 0 : 18) {
            if let title, !title.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            TVFocusableRowGrid(
                items: items,
                columnsPerRow: columnsPerRow,
                columnWidth: columnWidth,
                rowMinHeight: rowMinHeight,
                columnSpacing: columnSpacing,
                rowSpacing: rowSpacing,
                horizontalPadding: 14,
                verticalPadding: 12,
                content: content
            )
            .padding(.horizontal, -14)
            .padding(.vertical, -12)
        }
    }
}



struct TVFileListSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let items: [VideoFile]
    let content: (VideoFile) -> Content

    init(
        title: String,
        subtitle: String?,
        items: [VideoFile],
        @ViewBuilder content: @escaping (VideoFile) -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }

            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(items) { item in
                    content(item)
                        .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, -14)
            .padding(.vertical, -12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }
}



struct TVMediaLibraryPosterGrid<Content: View>: View {
    let items: [TVMediaLibraryNode]
    let content: (TVMediaLibraryNode) -> Content

    init(
        items: [TVMediaLibraryNode],
        @ViewBuilder content: @escaping (TVMediaLibraryNode) -> Content
    ) {
        self.items = items
        self.content = content
    }

    var body: some View {
        TVFocusableRowGrid(
            items: items,
            columnsPerRow: TVMediaLibraryLayout.posterGridColumnsPerRow,
            columnWidth: TVMediaLibraryLayout.posterGridColumnMaximum,
            rowMinHeight: TVMediaLibraryLayout.posterCardHeight,
            columnSpacing: TVMediaLibraryLayout.posterGridColumnSpacing,
            rowSpacing: TVMediaLibraryLayout.posterGridRowSpacing,
            content: content
        )
    }
}

struct TVMediaLibraryThumbGrid<Content: View>: View {
    let items: [TVMediaLibraryNode]
    let content: (TVMediaLibraryNode) -> Content

    init(
        items: [TVMediaLibraryNode],
        @ViewBuilder content: @escaping (TVMediaLibraryNode) -> Content
    ) {
        self.items = items
        self.content = content
    }

    var body: some View {
        TVFocusableRowGrid(
            items: items,
            columnsPerRow: 4,
            columnWidth: 340,
            rowMinHeight: 260,
            columnSpacing: 40,
            rowSpacing: 40,
            content: content
        )
    }
}



struct TVRatingArtworkBadge: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.caption.weight(.bold))
                .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.25))
            Text(String(format: "%.1f", rating))
                .font(.caption.weight(.bold))
                .foregroundColor(.white.opacity(0.94))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.56))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}



struct TVPlaybackProgressRing: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.22), lineWidth: lineWidth)

            if progress >= 1 {
                Circle()
                    .stroke(color, lineWidth: lineWidth + 0.7)
            } else {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth + 0.7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}



struct TVMediaPlaybackProgressBadge: View {
    let progress: Double
    let systemImageName: String
    let diameter: CGFloat

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var ringColor: Color {
        clampedProgress >= 0.98 ? Color(red: 0.34, green: 0.86, blue: 0.58) : TVShellStyle.accentSoft
    }

    var body: some View {
        ZStack {
            TVPlaybackProgressRing(
                progress: clampedProgress,
                color: ringColor,
                lineWidth: max(2.2, diameter * 0.07)
            )
            .frame(width: diameter + 6, height: diameter + 6)

            Circle()
                .fill(Color.black.opacity(0.74))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )

            Image(systemName: systemImageName)
                .font(.system(size: max(15, diameter * 0.40), weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: diameter + 6, height: diameter + 6)
        .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 5)
    }
}



struct TVDownloadedStatusIcon: View {
    var size: CGFloat = 18
    var showsShadow = true

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Color(red: 0.42, green: 0.88, blue: 0.58))
            .shadow(
                color: showsShadow ? Color.black.opacity(0.28) : .clear,
                radius: showsShadow ? 8 : 0,
                x: 0,
                y: showsShadow ? 4 : 0
            )
    }
}



struct TVStoredMediaPlaybackBadge: View {
    let file: VideoFile
    let progress: PlaybackProgressSnapshot?
    let diameter: CGFloat

    private var ringColor: Color {
        if progress?.isFinished == true {
            return Color(red: 0.34, green: 0.86, blue: 0.58)
        }
        return TVShellStyle.accentSoft
    }

    var body: some View {
        ZStack {
            if let progress {
                TVPlaybackProgressRing(
                    progress: progress.displayedProgress,
                    color: ringColor,
                    lineWidth: max(2.2, diameter * 0.07)
                )
                .frame(width: diameter + 6, height: diameter + 6)
            }

            Circle()
                .fill(Color.black.opacity(progress == nil ? 0.54 : 0.74))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )

            Image(systemName: file.tvPlaybackBadgeSystemImage)
                .font(.system(size: max(16, diameter * 0.42), weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: diameter + 6, height: diameter + 6)
        .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 5)
    }
}



struct TVStoredMediaSourceBadge: View {
    let file: VideoFile
    let server: ServerConfig?
    var maxWidth: CGFloat = 178

    private var serverType: ServerConfig.ServerType? {
        server?.type ?? file.serverType
    }

    private var title: String {
        if let serverType {
            return serverType.displayName
        }
        return file.tvHasRemoteOrigin ? platformShellString("Network") : platformShellString("Local")
    }

    private var fallbackSystemImageName: String {
        file.tvHasRemoteOrigin ? "server.rack" : "internaldrive.fill"
    }

    private var accentColor: Color {
        serverType?.tvAccentColor ?? TVShellStyle.accentSoft
    }

    var body: some View {
        HStack(spacing: 6) {
            if let serverType {
                TVServerTypeLogo(type: serverType, size: 20)
            } else {
                Image(systemName: fallbackSystemImageName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(width: 20, height: 20)
            }

            Text(title)
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(.white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 30)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.black.opacity(0.44),
                            Color.black.opacity(0.26)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(accentColor.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.20), radius: 7, x: 0, y: 4)
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .accessibilityHidden(true)
    }
}



struct TVPlexAuthorizationPanel: View {
    let pin: PlexLoginPin
    let linkURL: URL?
    let tintColor: Color

    private var qrString: String {
        linkURL?.absoluteString ?? "https://plex.tv/link/?pin=\(pin.code)"
    }

    private var codeText: String {
        Self.formattedCode(pin.code)
    }

    private var qrImage: UIImage? {
        TVQRCodeGenerator.image(from: qrString)
    }

    var body: some View {
        TVFocusableStaticPanel {
            HStack(alignment: .center, spacing: 30) {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 214, height: 214)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.92), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "qrcode")
                            .font(.title3.weight(.bold))
                            .foregroundColor(tintColor)

                        Text(platformShellString("Scan QR Code"))
                            .font(.title3.weight(.semibold))
                    }

                    Text(platformShellString("Platform Shell TV Plex Link Instructions"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 820, alignment: .leading)

                    Text("plex.tv/link")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(1)

                    Text(String(format: platformShellString("Plex code: %@"), codeText))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)

                    HStack(spacing: 12) {
                        ProgressView()
                        Text(platformShellString("Waiting for Plex authorization..."))
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .tvDetailPanel()
        }
    }

    private static func formattedCode(_ code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalized.count > 4 else { return normalized }

        let characters = Array(normalized)
        return stride(from: 0, to: characters.count, by: 4)
            .map { index in
                String(characters[index..<min(index + 4, characters.count)])
            }
            .joined(separator: " ")
    }
}



enum TVQRCodeGenerator {
    static func image(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}



struct TVInfoPanel: View {
    let title: String
    let message: String
    let systemImageName: String
    var kind: TVFeedbackPanelKind = .info
    var tintColor: Color? = nil

    var body: some View {
        TVFeedbackPanel(
            title: title,
            message: message,
            systemImageName: systemImageName,
            kind: kind,
            tintColor: tintColor
        )
    }
}



struct TVTextFieldPanel: View {
    let title: String
    let placeholder: String?
    @Binding var text: String
    var secure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            Group {
                if secure {
                    SecureField(placeholder ?? "", text: $text)
                } else {
                    TextField(placeholder ?? "", text: $text)
                }
            }
        }
        .tvDetailPanel()
    }
}



struct TVTogglePanel: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            TVTogglePanelLabel(
                title: title,
                subtitle: subtitle,
                isOn: isOn
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
        .tvFocusSectionIfAvailable()
    }
}



struct TVTogglePanelLabel: View {
    let title: String
    let subtitle: String?
    let isOn: Bool

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

    private var statusText: String {
        platformShellString(isOn ? "On" : "Off")
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(primaryColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.headline)
                        .foregroundColor(secondaryColor)
                }
            }

            Spacer(minLength: 0)

            Text(statusText)
                .font(.title3.weight(.medium))
                .foregroundColor(secondaryColor)
        }
        .tvInteractiveRowPanel()
    }
}



struct TVMaintenanceButtonLabel: View {
    let title: String
    let systemImageName: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var iconFillColor: Color {
        if showsFocus {
            return Color.black.opacity(0.10)
        }
        return TVShellStyle.accentSoft.opacity(isEnabled ? 0.14 : 0.06)
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(iconFillColor)

                Image(systemName: systemImageName)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundColor(primaryColor)
            }
            .frame(width: 54, height: 54)

            Text(title)
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(primaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 0)
        }
        .tvInteractiveRowPanel()
    }
}



struct TVMaintenanceButton: View {
    let title: String
    let systemImageName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVMaintenanceButtonLabel(title: title, systemImageName: systemImageName)
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVCompactActionButton: View {
    let title: String
    let systemImageName: String
    var isActive: Bool = false
    var isDestructive: Bool = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var backgroundFill: Color {
        if !isEnabled {
            return TVShellStyle.subtleFill.opacity(0.45)
        }
        if isDestructive {
            return isFocused ? Color(red: 0.95, green: 0.24, blue: 0.28).opacity(0.22) : Color(red: 0.95, green: 0.24, blue: 0.28).opacity(0.12)
        }
        if isFocused {
            return isActive ? TVShellStyle.accent.opacity(0.14) : TVShellStyle.elevatedSurface
        }
        return isActive ? TVShellStyle.accent.opacity(0.14) : TVShellStyle.surface
    }

    private var borderColor: Color {
        if !isEnabled {
            return TVShellStyle.separator
        }
        if isDestructive {
            return isFocused ? Color(red: 1.0, green: 0.46, blue: 0.48) : Color(red: 1.0, green: 0.32, blue: 0.36).opacity(0.42)
        }
        if isFocused {
            return TVShellStyle.focusStroke
        }
        return isActive ? TVShellStyle.accent.opacity(0.40) : TVShellStyle.separator
    }

    private var foregroundColor: Color {
        if isDestructive && isEnabled {
            return Color(red: 1.0, green: 0.50, blue: 0.52)
        }
        return isEnabled ? TVShellStyle.primary : TVShellStyle.secondary.opacity(0.45)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImageName)
                .foregroundColor(foregroundColor)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundColor(foregroundColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isFocused && isEnabled ? Color.clear : borderColor, lineWidth: 1.2)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: 16, showsFocus: isFocused && isEnabled, outerLineWidth: 2.6, innerInset: 3))
        .scaleEffect(isFocused && isEnabled ? 1.012 : 1.0)
        .shadow(
            color: isFocused && isEnabled ? Color.black.opacity(0.14) : .clear,
            radius: isFocused && isEnabled ? 8 : 0,
            x: 0,
            y: isFocused && isEnabled ? 4 : 0
        )
        .modifier(TVFocusedCardLayerModifier())
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .tvDisableSystemFocusEffect()
    }
}



struct TVTopChromeIconButton: View {
    let title: String
    let systemImageName: String
    var diameter: CGFloat = 74
    var badgeCount: Int = 0
    var onFocusChange: ((String, Bool) -> Void)? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    @Environment(\.colorScheme) private var colorScheme

    private var foregroundColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.45) }
        if showsFocus {
            return TVRowFocusStyle.primary(showsFocus: true, isEnabled: isEnabled, colorScheme: colorScheme)
        }
        return TVShellStyle.primary
    }

    private var fillColor: Color {
        if !isEnabled {
            return TVShellStyle.subtleFill.opacity(0.38)
        }
        if showsFocus {
            return TVRowFocusStyle.focusedFill(for: colorScheme)
        }
        return colorScheme == .dark ? Color.black.opacity(0.34) : TVShellStyle.subtleFill
    }

    private var strokeColor: Color {
        if showsFocus { return Color.clear }
        return Color.white.opacity(0.30)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemImageName)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(foregroundColor)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(fillColor)
                )
                .overlay(
                    Circle()
                        .stroke(strokeColor, lineWidth: 1.2)
                )


            if badgeCount > 0 {
                Text("\(min(badgeCount, 99))")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .padding(.horizontal, badgeCount > 9 ? 5 : 0)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.94, green: 0.20, blue: 0.28))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.black.opacity(0.42), lineWidth: 1.2)
                    )
                    .offset(x: 3, y: -3)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(showsFocus ? 1.035 : 1.0)
        .shadow(
            color: showsFocus ? Color.black.opacity(0.24) : Color.black.opacity(0.10),
            radius: showsFocus ? 16 : 8,
            x: 0,
            y: showsFocus ? 8 : 4
        )
        .modifier(TVFocusedCardLayerModifier())
        .accessibilityLabel(Text(title))
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .tvDisableSystemFocusEffect()
        .onChange(of: isFocused) { focused in
            onFocusChange?(title, focused && isEnabled)
        }
    }
}



struct TVDownloadsTopChromeButton: View {
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    var diameter: CGFloat = 74
    var onFocusChange: ((String, Bool) -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVTopChromeIconButton(
                title: platformShellString("Downloads"),
                systemImageName: "arrow.down.circle",
                diameter: diameter,
                badgeCount: downloadCenter.activeJobs.count,
                onFocusChange: onFocusChange
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVSearchPillButton: View {
    let title: String
    let systemImageName: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    @Environment(\.colorScheme) private var colorScheme

    private var foregroundColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.45) }
        if showsFocus {
            return TVRowFocusStyle.primary(showsFocus: true, isEnabled: isEnabled, colorScheme: colorScheme)
        }
        return TVShellStyle.primary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImageName)
                .font(.system(size: 25, weight: .bold))

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 28)
        .frame(height: 68)
        .contentShape(Capsule(style: .continuous))
        .background(
            Capsule(style: .continuous)
                .fill(showsFocus ? TVRowFocusStyle.focusedFill(for: colorScheme) : (colorScheme == .dark ? Color.black.opacity(0.34) : TVShellStyle.subtleFill))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(showsFocus ? Color.clear : Color.white.opacity(0.68), lineWidth: 2)
        )

        .scaleEffect(showsFocus ? 1.025 : 1.0)
        .shadow(color: showsFocus ? Color.black.opacity(0.25) : Color.black.opacity(0.12), radius: showsFocus ? 16 : 8, x: 0, y: showsFocus ? 8 : 4)
        .modifier(TVFocusedCardLayerModifier())
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .tvDisableSystemFocusEffect()
    }
}



struct TVCompactActionsRow<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                content()
            }
            .padding(.vertical, 4)
        }
    }
}



struct TVFocusableStaticPanel<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Button(action: {}) {
            content()
        }
        .buttonStyle(TVPlainButtonStyle())
    }
}



struct TVServerTypeInlineSelector: View {
    @Binding var selectedType: ServerConfig.ServerType
    @State private var isShowingPicker = false

    var body: some View {
        Button(action: { isShowingPicker = true }) {
            TVServerTypeDropdownLabel(selectedType: selectedType)
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
        .tvFocusSectionIfAvailable()
        .sheet(isPresented: $isShowingPicker) {
            TVServerTypePickerSheet(
                selectedType: $selectedType,
                isPresented: $isShowingPicker
            )
        }
    }
}

struct TVServerTypePickerSheet: View {
    @Binding var selectedType: ServerConfig.ServerType
    @Binding var isPresented: Bool
    @FocusState private var focusedType: ServerConfig.ServerType?

    private var cloudTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.cloudTypes }
    private var protocolTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.protocolTypes }
    private var mediaTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.mediaTypes }
    private var liveTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.liveTypes }

    var body: some View {
        TVPageScrollView(
            title: platformShellString("Server Type"),
            subtitle: nil,
            handlesExitCommand: true,
            customExitCommand: {
                isPresented = false
                return true
            },
            titleAccessory: AnyView(
                Button(action: { isPresented = false }) {
                    TVTopChromeIconButton(
                        title: platformShellString("Close"),
                        systemImageName: "xmark",
                        diameter: 58
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            )
        ) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(platformShellString("Media Servers"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVShellStyle.secondary)
                        .padding(.leading, 8)

                    ForEach(mediaTypes, id: \.self) { type in
                        typeButton(for: type)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(platformShellString("File Protocols"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVShellStyle.secondary)
                        .padding(.leading, 8)

                    ForEach(protocolTypes, id: \.self) { type in
                        typeButton(for: type)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(platformShellString("Live TV"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVShellStyle.secondary)
                        .padding(.leading, 8)

                    ForEach(liveTypes, id: \.self) { type in
                        typeButton(for: type)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(platformShellString("Cloud Drives"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVShellStyle.secondary)
                        .padding(.leading, 8)

                    ForEach(cloudTypes, id: \.self) { type in
                        typeButton(for: type)
                    }
                }
            }
            .frame(width: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedType = selectedType
            }
        }
    }

    private func typeButton(for type: ServerConfig.ServerType) -> some View {
        Button(action: {
            selectedType = type
            isPresented = false
        }) {
            TVServerTypeChoiceRow(
                type: type,
                isSelected: selectedType == type
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
        .focused($focusedType, equals: type)
    }
}

struct TVServerTypeChoiceRow: View {
    let type: ServerConfig.ServerType
    let isSelected: Bool

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

    var body: some View {
        HStack(spacing: 20) {
            TVServerTypeLogo(type: type, size: 54, showsBackground: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(type.displayName)
                        .strikethrough(type == .googledrive)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(primaryColor)

                    if type.isBeta {
                        Text("Beta")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }

                Text(type.tvProtocolSubtitle)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(secondaryColor)
            }

            Spacer(minLength: 16)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(
                        showsFocus
                        ? TVRowFocusStyle.primary(showsFocus: true, isEnabled: true, colorScheme: colorScheme)
                        : TVShellStyle.accent
                    )
            }
        }
        .tvInteractiveRowPanel()
    }
}

private struct TVServerTypeDropdownLabel: View {
    let selectedType: ServerConfig.ServerType

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

    var body: some View {
        HStack(spacing: 20) {
            TVServerTypeLogo(type: selectedType, size: 54, showsBackground: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(platformShellString("Server Type"))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(secondaryColor)

                Text(selectedType.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundColor(primaryColor)
            }

            Spacer(minLength: 16)

            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(secondaryColor)
        }
        .tvInteractiveRowPanel()
    }
}

// MARK: - TV Category Tab Button (Handles high-contrast focus and selection states for IPTV and Media Library)

struct TVCategoryTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(
                isFocused
                ? .black
                : (isSelected ? .white : TVShellStyle.primary)
            )
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isFocused
                        ? Color.white
                        : (isSelected ? TVShellStyle.accent : TVShellStyle.surface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isFocused ? Color.clear : (isSelected ? Color.clear : TVShellStyle.glassStroke), lineWidth: 1)
            )
            .overlay(
                TVFocusedBlockOverlay(cornerRadius: 16, showsFocus: isFocused)
            )
            .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.96 : 1.0))
            .shadow(
                color: isFocused ? Color.black.opacity(0.38) : Color.clear,
                radius: isFocused ? 18 : 0,
                x: 0,
                y: isFocused ? 8 : 0
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .tvDisableSystemFocusEffect()
    }
}

struct TVCategoryTabButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    var iconName: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let iconName = iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 22, weight: .bold))

                Text("\(count)")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.14))
                    )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .buttonStyle(TVCategoryTabButtonStyle(isSelected: isSelected))
    }
}
#endif
