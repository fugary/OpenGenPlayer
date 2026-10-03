import SwiftUI
#if os(iOS)
import UIKit
#endif

func mediaLibrarySupportsNativeSearchBar() -> Bool {
    #if os(tvOS)
    return false
    #else
    if #available(iOS 15.0, *) {
        return true
    }
    return false
    #endif
}

extension Sequence where Element: Identifiable, Element.ID: Hashable {
    func stableUniqued() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}

struct NavigationLazyView<Content: View>: View {
    private let build: () -> Content

    init(@ViewBuilder _ build: @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}

private struct PersistentSystemOverlaysCompatModifier: ViewModifier {
    let hidden: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.persistentSystemOverlays(hidden ? .hidden : .visible)
        } else {
            content
        }
    }
}

extension View {
    func persistentSystemOverlaysCompat(hidden: Bool) -> some View {
        modifier(PersistentSystemOverlaysCompatModifier(hidden: hidden))
    }
}

struct ScaleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct FloatingToastModifier: ViewModifier {
    @Binding var message: String?
    let tint: Color
    @State private var hideWorkItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content

            if let message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(tint.opacity(0.95))
                    )
                    .padding(.top, 12)
                    .padding(.horizontal, 20)
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        let workItem = DispatchWorkItem {
                            withAnimation(.easeOut(duration: 0.18)) {
                                self.message = nil
                            }
                        }
                        hideWorkItem?.cancel()
                        hideWorkItem = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: workItem)
                    }
            }
        }
            .animation(.spring(response: 0.25, dampingFraction: 0.88), value: message)
    }
}

extension View {
    @ViewBuilder
    func applyIf<Transformed: View>(_ condition: Bool, transform: (Self) -> Transformed) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    @ViewBuilder
    func refreshableCompat(action: @escaping @Sendable () async -> Void) -> some View {
        if #available(iOS 15.0, *) {
            self.refreshable(action: action)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func hideTabBarCompat() -> some View {
        self.background(TabVisibilityEnforcer(hidden: true))
    }
    
    @ViewBuilder
    func showTabBarCompat() -> some View {
        self.background(TabVisibilityEnforcer(hidden: false))
    }
    
    @ViewBuilder
    func searchableCompat(
        text: Binding<String>,
        prompt: String = NSLocalizedString("Search", comment: ""),
        preferUIKitOnPad: Bool = false
    ) -> some View {
        if #available(iOS 15.0, *) {
            if preferUIKitOnPad && UIDevice.current.userInterfaceIdiom == .pad {
                self.background(
                    NavigationSearchControllerConfigurator(text: text, prompt: prompt)
                )
            } else {
                let displayMode: SearchFieldPlacement.NavigationBarDrawerDisplayMode = .automatic
                self.searchable(text: text, placement: .navigationBarDrawer(displayMode: displayMode), prompt: prompt)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func onSearchSubmitCompat(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 15.0, *) {
            self.onSubmit(of: .search, action)
        } else {
            self
        }
    }

    func floatingToast(message: Binding<String?>, tint: Color = .green) -> some View {
        modifier(FloatingToastModifier(message: message, tint: tint))
    }

    @ViewBuilder
    func libraryChildNavigationBarCompat() -> some View {
        #if os(iOS)
        self.navigationBarHidden(false)
        #else
        self
        #endif
    }

    func navigationTitleIconCompat(
        title: String,
        imageAssetName: String,
        fallbackSystemName: String,
        accessibilityLabel: String,
        showsInlineTitle: Bool,
        titleColor: UIColor? = nil
    ) -> some View {
        self.background(
            NavigationTitleIconConfigurator(
                title: title,
                image: UIImage(named: imageAssetName),
                fallbackSystemName: fallbackSystemName,
                accessibilityLabel: accessibilityLabel,
                showsInlineTitle: showsInlineTitle,
                titleColor: titleColor
            )
        )
    }

    // Quick pop-to-root for deep navigation hierarchies in iOS 14+
    func popToRoot() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first(where: { $0.isKeyWindow }),
           let rootViewController = window.rootViewController {
            
            // Function to recursively find the active UINavigationController
            func findNavigationController(viewController: UIViewController?) -> UINavigationController? {
                if let navigationController = viewController as? UINavigationController {
                    return navigationController
                }
                if let tabBarController = viewController as? UITabBarController {
                    return findNavigationController(viewController: tabBarController.selectedViewController)
                }
                for child in viewController?.children ?? [] {
                    if let found = findNavigationController(viewController: child) {
                        return found
                    }
                }
                return nil
            }
            
            if let navigationController = findNavigationController(viewController: rootViewController) {
                navigationController.popToRootViewController(animated: true)
            }
        }
    }
    
    // Quick pop-to-server-root for deep navigation hierarchies in iOS 14+
    // Since we now use .fullScreenCover with a new NavigationView for servers,
    // the server root itself is at index 0.
    func popToServerRoot() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first(where: { $0.isKeyWindow }),
           let rootViewController = window.rootViewController {
            
            // Function to recursively find the active UINavigationController
            func findNavigationController(viewController: UIViewController?) -> UINavigationController? {
                guard let viewController = viewController else { return nil }
                
                if let presented = viewController.presentedViewController {
                    if let found = findNavigationController(viewController: presented) {
                        return found
                    }
                }
                
                if let tabBarController = viewController as? UITabBarController {
                    return findNavigationController(viewController: tabBarController.selectedViewController)
                }
                
                if let splitViewController = viewController as? UISplitViewController {
                    if let detail = splitViewController.viewControllers.last,
                       let found = findNavigationController(viewController: detail) {
                        return found
                    }
                }
                
                if let navigationController = viewController as? UINavigationController {
                    return navigationController
                }
                
                for child in viewController.children.reversed() {
                    if let found = findNavigationController(viewController: child) {
                        return found
                    }
                }
                return nil
            }
            
            if let navigationController = findNavigationController(viewController: rootViewController) {
                navigationController.popToRootViewController(animated: true)
            }
        }
    }
}

/// Adds a left-edge swipe gesture to dismiss a full screen cover or modal.
/// Includes an interactive visual indicator (thumb-tracking xmark) similar to Android's back gesture.
struct EdgeSwipeDismissModifier: ViewModifier {
    var onDismiss: () -> Void
    
    @State private var dragOffset: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var isActive: Bool = false
    
    #if os(iOS)
    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            content
            
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Invisible capture area on the left edge
                    Color.white.opacity(0.001)
                        .frame(width: 25, height: geo.size.height)
                        // highPriorityGesture helps prevent inner ScrollViews from swallowing the gesture
                        // after navigating back and forth in the stack.
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                                .onChanged { value in
                                    if value.startLocation.x < 30 && value.translation.width > 0 {
                                        dragOffset = value.translation.width
                                        dragY = value.location.y
                                        
                                        let newIsActive = value.translation.width > 70
                                        if newIsActive != isActive {
                                            isActive = newIsActive
                                            if newIsActive {
                                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                            }
                                        }
                                    }
                                }
                                .onEnded { value in
                                    if value.startLocation.x < 30 && value.translation.width > 70 {
                                        onDismiss()
                                    }
                                    withAnimation(.spring()) {
                                        dragOffset = 0
                                        isActive = false
                                    }
                                }
                        )
                    
                    // Visual Indicator
                    if dragOffset > 0 {
                        let pullPercent = min(dragOffset / 70.0, 1.0)
                        
                        ZStack {
                            // The background shape (mimicking a waterdrop/bubble)
                            Capsule()
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                                .shadow(color: Color.black.opacity(0.15), radius: isActive ? 6 : 3, x: 0, y: 2)
                                .frame(width: isActive ? 52 : 44 + (12 * pullPercent), height: isActive ? 52 : 44)
                            
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: isActive ? 22 : 18, weight: .semibold))
                                .foregroundColor(isActive ? Color.accentColor : Color.primary.opacity(0.7))
                        }
                        .offset(x: -30 + min(dragOffset, 80), y: dragY - 22)
                        .opacity(min(Double(dragOffset / 30.0), 1.0))
                    }
                }
            }
            .ignoresSafeArea()
            .zIndex(999)
        }
    }
    #else
    func body(content: Content) -> some View {
        content
    }
    #endif
}

extension View {
    /// Adds a left edge swipe gesture to trigger the provided dismiss action.
    /// Primarily used for root views of fullScreenCovers to allow interactive dismissal.
    func edgeSwipeToDismiss(action: (() -> Void)?) -> some View {
        Group {
            if let action = action {
                self.modifier(EdgeSwipeDismissModifier(onDismiss: action))
            } else {
                self
            }
        }
    }
}

extension UIApplication {
    static func activeWindowScene() -> UIWindowScene? {
        activeKeyWindow()?.windowScene
    }

    static func activeKeyWindow() -> UIWindow? {
        let scenes = shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                func rank(_ state: UIScene.ActivationState) -> Int {
                    switch state {
                    case .foregroundActive: return 0
                    case .foregroundInactive: return 1
                    case .background: return 2
                    case .unattached: return 3
                    @unknown default: return 4
                    }
                }

                return rank(lhs.activationState) < rank(rhs.activationState)
            }

        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
            if let window = scene.windows.first(where: { $0.windowLevel == .normal && !$0.isHidden }) {
                return window
            }
        }

        return nil
    }

    static func currentSafeAreaInsets() -> UIEdgeInsets {
        activeKeyWindow()?.safeAreaInsets ?? .zero
    }

    static func resolvedInterfaceOrientation(for windowScene: UIWindowScene) -> UIInterfaceOrientation {
        let orientation = windowScene.interfaceOrientation
        if orientation.isPortrait || orientation.isLandscape {
            return orientation
        }

        let size = windowScene.coordinateSpace.bounds.size
        return size.width > size.height ? .landscapeRight : .portrait
    }

    static func activeInterfaceOrientation() -> UIInterfaceOrientation {
        if let windowScene = activeWindowScene() {
            return resolvedInterfaceOrientation(for: windowScene)
        }

        let deviceOrientation = UIDevice.current.orientation
        if deviceOrientation.isLandscape {
            return .landscapeRight
        }
        return .portrait
    }

    static func forceRotation(to orientation: UIInterfaceOrientation) {
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        UINavigationController.attemptRotationToDeviceOrientation()
    }

    static func topMostViewController(from root: UIViewController? = activeKeyWindow()?.rootViewController) -> UIViewController? {
        guard let root = root else { return nil }
        if let presented = root.presentedViewController {
            return topMostViewController(from: presented)
        }
        if let navigationController = root as? UINavigationController {
            return topMostViewController(from: navigationController.visibleViewController) ?? navigationController
        }
        if let tabBarController = root as? UITabBarController {
            return topMostViewController(from: tabBarController.selectedViewController) ?? tabBarController
        }
        return root
    }

    static func requestInterfaceOrientation(
        _ targetInterfaceOrientation: UIInterfaceOrientation,
        lock targetOrientationMask: UIInterfaceOrientationMask,
        allowForceFallback: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        if #available(iOS 16.0, *) {
            guard let window = activeKeyWindow(),
                  let windowScene = window.windowScene else {
                completion(false)
                return
            }

            AppDelegate.orientationLock = targetOrientationMask
            topMostViewController(from: window.rootViewController)?
                .setNeedsUpdateOfSupportedInterfaceOrientations()

            var hasCompleted = false
            func finish(_ success: Bool) {
                guard !hasCompleted else { return }
                hasCompleted = true
                DispatchQueue.main.async {
                    completion(success)
                }
            }

            func verifyRotation(hasForcedFallback: Bool) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    let latestOrientation = resolvedInterfaceOrientation(for: windowScene)
                    let didRotate = targetInterfaceOrientation.isLandscape
                        ? latestOrientation.isLandscape
                        : latestOrientation.isPortrait

                    if didRotate {
                        finish(true)
                    } else if allowForceFallback && !hasForcedFallback {
                        forceRotation(to: targetInterfaceOrientation)
                        verifyRotation(hasForcedFallback: true)
                    } else {
                        finish(false)
                    }
                }
            }

            windowScene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetOrientationMask)
            ) { error in
                print("Rotation error: \(error.localizedDescription)")
            }

            verifyRotation(hasForcedFallback: false)
        } else {
            AppDelegate.orientationLock = targetOrientationMask
            forceRotation(to: targetInterfaceOrientation)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                let latestOrientation = activeInterfaceOrientation()
                let didRotate = targetInterfaceOrientation.isLandscape
                    ? latestOrientation.isLandscape
                    : latestOrientation.isPortrait
                completion(didRotate)
            }
        }
    }

    static func refreshInterfaceChrome(delays: [TimeInterval] = [0, 0.12, 0.3]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = activeKeyWindow() else { return }
                if let rootViewController = window.rootViewController {
                    rootViewController.refreshSystemChromeRecursively()
                    rootViewController.view.setNeedsLayout()
                    rootViewController.view.layoutIfNeeded()
                }
                window.setNeedsLayout()
                window.layoutIfNeeded()
                UINavigationController.attemptRotationToDeviceOrientation()
            }
        }
    }
}

private extension UIViewController {
    func refreshSystemChromeRecursively() {
        setNeedsStatusBarAppearanceUpdate()
        if #available(iOS 11.0, *) {
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        children.forEach { $0.refreshSystemChromeRecursively() }
        presentedViewController?.refreshSystemChromeRecursively()
    }
}

struct SafeAreaInsetReader: UIViewRepresentable {
    var onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> SafeAreaInsetObservingView {
        let view = SafeAreaInsetObservingView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: SafeAreaInsetObservingView, context: Context) {
        uiView.onChange = onChange
        DispatchQueue.main.async {
            uiView.reportSafeAreaIfNeeded()
        }
    }
}

enum MediaLibraryTitleStyle {
    case large
    case inline

    var iconSize: CGFloat {
        switch self {
        case .large: return 30
        case .inline: return 18
        }
    }

    var spacing: CGFloat {
        switch self {
        case .large: return 10
        case .inline: return 8
        }
    }

    var font: Font {
        switch self {
        case .large: return .system(size: 34, weight: .bold)
        case .inline: return .headline.weight(.semibold)
        }
    }
}

struct MediaLibraryTitleRow: View {
    let title: String
    let type: ServerConfig.ServerType
    let style: MediaLibraryTitleStyle

    var body: some View {
        HStack(alignment: .center, spacing: style.spacing) {
            ServerTypeIconMark(type: type, size: style.iconSize)

            Text(title)
                .font(style.font)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(type.displayName) \(title)"))
    }
}

struct MediaLibraryInlineNavigationTitle: View {
    let title: String
    let type: ServerConfig.ServerType
    let isVisible: Bool

    var body: some View {
        MediaLibraryTitleRow(title: title, type: type, style: .inline)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
            .animation(.easeInOut(duration: 0.18), value: isVisible)
    }
}

struct ServerTypeIconMark: View {
    let type: ServerConfig.ServerType
    let size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(named: type.iconAssetName) {
                Image(uiImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: type.systemIconName)
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundColor(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
    }
}

struct MediaSectionHeaderLabel: View {
    let title: String
    let systemImage: String?
    var foregroundColor: Color = .primary
    var font: Font = .title2
    var weight: Font.Weight = .bold

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(foregroundColor.opacity(0.92))
            }

            Text(title)
                .font(font)
                .fontWeight(weight)
                .foregroundColor(foregroundColor)
        }
    }
}

struct MediaLibraryInlineActionRow: View {
    let title: String
    let subtitle: String?
    let detail: String?
    let leadingSystemImage: String
    let accentColor: Color
    let trailingSystemImage: String
    let trailingColor: Color
    var foregroundColor: Color = .white

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accentColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )

                Image(systemName: leadingSystemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(accentColor)
            }
            .frame(width: 140, height: 80)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(foregroundColor)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(foregroundColor.opacity(0.64))
                        .lineLimit(1)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(foregroundColor.opacity(0.82))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: trailingSystemImage)
                .font(.title2)
                .foregroundColor(trailingColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

enum AppToolbarIconStyle {
    case primary
    case secondary
    case destructive

    var foregroundColor: Color {
        switch self {
        case .primary:
            return Color(UIColor.label)
        case .secondary:
            return Color(UIColor.secondaryLabel)
        case .destructive:
            return Color(UIColor.systemRed)
        }
    }
}

extension View {
    /// Keep Back and Home in one ordered navigation group, like library categories.
    /// Mixing cancellationAction and navigationBarLeading can reorder them vertically.
    @ViewBuilder
    func mediaLibraryNavigationToolbar<Back: View, Home: View>(
        @ViewBuilder back: () -> Back,
        @ViewBuilder home: () -> Home
    ) -> some View {
        // iOS 27.1 SDK ships SwiftUI 8.0.85.27. Xcode 27.0 uses the same Swift
        // compiler, so gate these SDK-only APIs by module version as well as runtime OS.
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            self.toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    back()
                    home()
                }
                .axisBehavior(.verticalPreferred)
            }
        } else {
            self.toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    back()
                    home()
                }
            }
        }
        #else
        self.toolbar {
            ToolbarItemGroup(placement: .navigation) {
                back()
                home()
            }
        }
        #endif
    }
}

struct AppToolbarIcon: View {
    let systemName: String
    var badgeCount: Int = 0
    var style: AppToolbarIconStyle = .primary
    var fontSize: CGFloat? = nil
    /// Pre-Liquid Glass compatibility for transparent media-library toolbars.
    /// Modern iOS uses the native foreground, with hierarchy for secondary actions.
    var legacyForegroundColor: Color? = nil

    /// Server exits use the same native contrast as other navigation actions.
    /// Keep each caller's previous styling on older systems and other platforms.
    static func serverExit(
        legacyStyle: AppToolbarIconStyle = .primary,
        legacyForegroundColor: Color? = nil
    ) -> AppToolbarIcon {
        var style = legacyStyle
        #if os(iOS)
        if #available(iOS 26.0, *) {
            style = .primary
        }
        #endif
        return AppToolbarIcon(
            systemName: "rectangle.portrait.and.arrow.right",
            style: style,
            legacyForegroundColor: legacyForegroundColor
        )
    }

    private var containerSize: CGFloat {
        badgeCount > 0 ? 32 : 24
    }

    private var effectiveFontSize: CGFloat? {
        if let fontSize = fontSize {
            return fontSize
        }
        if systemName.hasPrefix("eye") {
            return 15
        }
        return nil
    }

    @ViewBuilder
    private var symbol: some View {
        if let size = effectiveFontSize {
            Image(systemName: systemName)
                .font(.system(size: size))
        } else {
            Image(systemName: systemName)
        }
    }

    @ViewBuilder
    private var styledSymbol: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // Leave primary symbols to the toolbar; hierarchical secondary
            // styling also preserves the native material's adaptive foreground.
            switch style {
            case .primary:
                symbol
            case .secondary:
                symbol.foregroundStyle(.secondary)
            case .destructive:
                symbol.foregroundStyle(Color(UIColor.systemRed))
            }
        } else {
            symbol.foregroundColor(legacyForegroundColor ?? style.foregroundColor)
        }
        #else
        symbol.foregroundColor(legacyForegroundColor ?? style.foregroundColor)
        #endif
    }

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *), badgeCount <= 0 {
            // Keep ordinary labels as native symbols. The toolbar owns their
            // sizing, hit targets, material and adaptive foreground.
            styledSymbol
        } else {
            boundedIcon
        }
        #else
        boundedIcon
        #endif
    }

    private var boundedIcon: some View {
        ZStack(alignment: .topTrailing) {
            styledSymbol
                .frame(width: 24, height: 24)

            if badgeCount > 0 {
                Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, badgeCount > 99 ? 4 : 3)
                    .padding(.vertical, 1)
                    .background(Color.red)
                    .clipShape(Capsule())
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .frame(width: containerSize, height: containerSize, alignment: .center)
        .contentShape(Rectangle())
    }
}

struct MediaLibrarySearchButton: View {
    let prompt: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 16, weight: .medium))

            Text(prompt)
                .font(.body)
                .foregroundColor(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemGray6))
        .clipShape(Capsule())
    }
}

struct MediaLibraryHeaderOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Transparent Navigation Bar Support

extension View {
    /// Makes the navigation bar transparent (no background) when `isTransparent` is true.
    /// When `isTransparent` is false, restores the system default appearance.
    /// This is required for full-bleed content (e.g., home carousel) to extend behind the nav bar.
    @ViewBuilder
    func navBarTransparentCompat(isTransparent: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // The scroll edge effect is separate from the bar background. Both
            // must be hidden while the carousel extends behind the toolbar.
            self.toolbarBackground(isTransparent ? .hidden : .automatic, for: .navigationBar)
                .scrollEdgeEffectHidden(isTransparent, for: .top)
        } else {
            self.background(
                NavBarAppearanceConfigurator(isTransparent: isTransparent)
            )
        }
        #else
        self.background(
            NavBarAppearanceConfigurator(isTransparent: isTransparent)
        )
        #endif
    }
}

struct NavBarAppearanceConfigurator: UIViewControllerRepresentable {
    let isTransparent: Bool

    func makeUIViewController(context: Context) -> NavBarAppearanceHost {
        let host = NavBarAppearanceHost()
        host.apply(isTransparent: isTransparent)
        return host
    }

    func updateUIViewController(_ uiViewController: NavBarAppearanceHost, context: Context) {
        uiViewController.apply(isTransparent: isTransparent)
    }
}

final class NavBarAppearanceHost: UIViewController {
    private var currentIsTransparent: Bool?
    private var workItem: DispatchWorkItem?

    func apply(isTransparent: Bool) {
        guard currentIsTransparent != isTransparent else { return }
        currentIsTransparent = isTransparent
        scheduleApply(isTransparent: isTransparent)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if let t = currentIsTransparent { scheduleApply(isTransparent: t) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let t = currentIsTransparent { scheduleApply(isTransparent: t) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // When leaving, always restore to system default
        if isMovingFromParent {
            scheduleApply(isTransparent: false)
        }
    }

    deinit {
        workItem?.cancel()
    }

    private func scheduleApply(isTransparent: Bool) {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyAppearance(isTransparent: isTransparent)
        }
        workItem = item
        DispatchQueue.main.async(execute: item)
    }

    /// Traverse the parent chain to find a controller that has a navigationController,
    /// matching the pattern used by NavigationTitleIconHost.
    private func hostingController() -> UIViewController? {
        var current = parent
        while let controller = current {
            if controller.navigationController != nil {
                return controller
            }
            current = controller.parent
        }
        return parent
    }

    private func applyAppearance(isTransparent: Bool) {
        guard let host = hostingController(),
              let navBar = host.navigationController?.navigationBar else { return }
        if isTransparent {
            let transparentAppearance = UINavigationBarAppearance()
            transparentAppearance.configureWithTransparentBackground()
            transparentAppearance.shadowColor = .clear
            navBar.standardAppearance = transparentAppearance
            navBar.scrollEdgeAppearance = transparentAppearance
            navBar.compactAppearance = transparentAppearance
        } else {
            // Restore system defaults
            let defaultAppearance = UINavigationBarAppearance()
            defaultAppearance.configureWithDefaultBackground()
            navBar.standardAppearance = defaultAppearance
            navBar.scrollEdgeAppearance = nil
            navBar.compactAppearance = nil
        }
    }
}

#if os(iOS)
struct NavigationTitleIconConfigurator: UIViewControllerRepresentable {
    let title: String
    let image: UIImage?
    let fallbackSystemName: String
    let accessibilityLabel: String
    let showsInlineTitle: Bool
    let titleColor: UIColor?

    func makeUIViewController(context: Context) -> NavigationTitleIconHost {
        let controller = NavigationTitleIconHost()
        controller.update(
            title: title,
            image: image,
            fallbackSystemName: fallbackSystemName,
            accessibilityLabel: accessibilityLabel,
            showsInlineTitle: showsInlineTitle,
            titleColor: titleColor
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: NavigationTitleIconHost, context: Context) {
        uiViewController.update(
            title: title,
            image: image,
            fallbackSystemName: fallbackSystemName,
            accessibilityLabel: accessibilityLabel,
            showsInlineTitle: showsInlineTitle,
            titleColor: titleColor
        )
    }
}

final class NavigationTitleIconHost: UIViewController {
    private weak var owningController: UIViewController?
    private weak var adjustedLargeTitleLabel: UILabel?
    private var originalLargeTitleFrame: CGRect?
    private var titleText: String = ""
    private var sourceImage: UIImage?
    private var fallbackSystemName: String = ""
    private var accessibilityText: String = ""
    private var showsInlineTitle = false
    private var configuredTitleColor: UIColor?
    private var configureWorkItem: DispatchWorkItem?

    private lazy var largeTitleIconView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
        return view
    }()

    private lazy var inlineTitleIconView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 16),
            view.heightAnchor.constraint(equalToConstant: 16)
        ])
        return view
    }()

    private lazy var inlineTitleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var inlineTitleStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [inlineTitleIconView, inlineTitleLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        return stack
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        configureTitleIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureTitleIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureTitleIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureTitleIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            detachTitleCustomizations()
        }
    }

    deinit {
        configureWorkItem?.cancel()
        detachTitleCustomizations()
    }

    func update(
        title: String,
        image: UIImage?,
        fallbackSystemName: String,
        accessibilityLabel: String,
        showsInlineTitle: Bool,
        titleColor: UIColor?
    ) {
        titleText = title
        sourceImage = image
        self.fallbackSystemName = fallbackSystemName
        accessibilityText = accessibilityLabel
        self.showsInlineTitle = showsInlineTitle
        self.configuredTitleColor = titleColor
        configureTitleIfNeeded()
    }

    private func configureTitleIfNeeded() {
        configureWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyTitleCustomization()
        }
        configureWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func applyTitleCustomization() {
        guard let hostController = hostingController(),
              let navigationController = hostController.navigationController else { return }

        owningController = hostController
        let navigationBar = navigationController.navigationBar
        let resolvedImage = resolvedTitleImage()

        inlineTitleLabel.text = titleText
        inlineTitleLabel.textColor = configuredTitleColor ?? .label
        inlineTitleIconView.image = resolvedImage
        inlineTitleIconView.tintColor = sourceImage == nil ? (configuredTitleColor ?? .label) : nil
        inlineTitleStack.accessibilityLabel = accessibilityText
        inlineTitleStack.sizeToFit()

        if showsInlineTitle {
            restoreLargeTitleLabelFrame()
            largeTitleIconView.removeFromSuperview()
            if hostController.navigationItem.titleView !== inlineTitleStack {
                hostController.navigationItem.titleView = inlineTitleStack
            }
            return
        }

        if hostController.navigationItem.titleView === inlineTitleStack {
            hostController.navigationItem.titleView = nil
        }

        _ = installLargeTitleIconIfNeeded(on: navigationBar, image: resolvedImage)
    }

    @discardableResult
    private func installLargeTitleIconIfNeeded(on navigationBar: UINavigationBar, image: UIImage?) -> Bool {
        let largeTitleView = largeTitleContainer(in: navigationBar) ?? navigationBar

        guard let titleLabel = largeTitleLabel(in: largeTitleView) else {
            restoreLargeTitleLabelFrame()
            largeTitleIconView.removeFromSuperview()
            return false
        }

        let isLargeTitleVisible = !titleLabel.isHidden &&
            titleLabel.alpha > 0.01 &&
            largeTitleView.bounds.height > 32 &&
            titleLabel.font.pointSize > 24 &&
            titleLabel.bounds.width > 0

        guard isLargeTitleVisible else {
            restoreLargeTitleLabelFrame()
            largeTitleIconView.removeFromSuperview()
            return false
        }

        if adjustedLargeTitleLabel !== titleLabel {
            restoreLargeTitleLabelFrame()
            adjustedLargeTitleLabel = titleLabel
            originalLargeTitleFrame = titleLabel.frame
        } else if titleLabel.frame.minX < 30 {
            originalLargeTitleFrame = titleLabel.frame
        }

        let iconSize = min(max(18, titleLabel.font.pointSize * 0.72), 26)
        let spacing: CGFloat = 8
        let baseFrame = originalLargeTitleFrame ?? titleLabel.frame
        let iconX = baseFrame.minX
        let desiredLabelX = baseFrame.minX + iconSize + spacing

        var labelFrame = baseFrame
        labelFrame.origin.x = desiredLabelX
        titleLabel.frame = labelFrame.integral

        largeTitleIconView.image = image
        largeTitleIconView.tintColor = sourceImage == nil ? .label : nil
        largeTitleIconView.frame = CGRect(
            x: iconX,
            y: labelFrame.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        ).integral

        if largeTitleIconView.superview !== largeTitleView {
            largeTitleIconView.removeFromSuperview()
            largeTitleView.addSubview(largeTitleIconView)
        }
        largeTitleView.bringSubviewToFront(largeTitleIconView)
        largeTitleView.accessibilityLabel = accessibilityText
        return true
    }

    private func detachTitleCustomizations() {
        configureWorkItem?.cancel()
        restoreLargeTitleLabelFrame()
        largeTitleIconView.removeFromSuperview()
        if let owner = owningController, owner.navigationItem.titleView === inlineTitleStack {
            owner.navigationItem.titleView = nil
        }
    }

    private func restoreLargeTitleLabelFrame() {
        if let label = adjustedLargeTitleLabel, let originalFrame = originalLargeTitleFrame {
            label.frame = originalFrame
        }
        adjustedLargeTitleLabel = nil
        originalLargeTitleFrame = nil
    }

    private func resolvedTitleImage() -> UIImage? {
        if let image = sourceImage {
            return image.withRenderingMode(.alwaysOriginal)
        }
        return UIImage(systemName: fallbackSystemName)?.withRenderingMode(.alwaysTemplate)
    }

    private func largeTitleLabel(in view: UIView) -> UILabel? {
        let labels = allLabels(in: view)
        if let exactMatch = labels.first(where: { $0.text == titleText }) {
            return exactMatch
        }
        return labels.max(by: { $0.font.pointSize < $1.font.pointSize })
    }

    private func allLabels(in view: UIView) -> [UILabel] {
        var labels: [UILabel] = []
        if let label = view as? UILabel {
            labels.append(label)
        }
        for subview in view.subviews {
            labels.append(contentsOf: allLabels(in: subview))
        }
        return labels
    }

    private func largeTitleContainer(in view: UIView) -> UIView? {
        if String(describing: type(of: view)).contains("LargeTitleView") {
            return view
        }

        for subview in view.subviews {
            if let match = largeTitleContainer(in: subview) {
                return match
            }
        }

        return nil
    }

    private func hostingController() -> UIViewController? {
        var current = parent
        while let controller = current {
            if controller.navigationController != nil {
                return controller
            }
            current = controller.parent
        }
        return parent
    }
}

#if os(iOS)
@available(iOS 15.0, *)
struct NavigationSearchControllerConfigurator: UIViewControllerRepresentable {
    @Binding var text: String
    let prompt: String

    func makeUIViewController(context: Context) -> NavigationSearchControllerHost {
        let controller = NavigationSearchControllerHost()
        controller.update(text: $text, prompt: prompt)
        return controller
    }

    func updateUIViewController(_ uiViewController: NavigationSearchControllerHost, context: Context) {
        uiViewController.update(text: $text, prompt: prompt)
    }
}

@available(iOS 15.0, *)
final class NavigationSearchControllerHost: UIViewController, UISearchResultsUpdating, UISearchBarDelegate {
    private var textBinding: Binding<String> = .constant("")
    private var promptText: String = ""
    private weak var owningController: UIViewController?
    private var configureWorkItem: DispatchWorkItem?
    private var configuredOwnerID: ObjectIdentifier?

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchResultsUpdater = self
        controller.searchBar.delegate = self
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        return controller
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        configureSearchControllerIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureSearchControllerIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureSearchControllerIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            detachSearchControllerIfNeeded()
        }
    }

    deinit {
        configureWorkItem?.cancel()
        detachSearchControllerIfNeeded()
    }

    func update(text: Binding<String>, prompt: String) {
        textBinding = text
        promptText = prompt
        configureSearchControllerIfNeeded()
        syncSearchBarText()
    }

    func updateSearchResults(for searchController: UISearchController) {
        let newText = searchController.searchBar.text ?? ""
        guard textBinding.wrappedValue != newText else { return }
        DispatchQueue.main.async {
            self.textBinding.wrappedValue = newText
        }
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        if !textBinding.wrappedValue.isEmpty {
            textBinding.wrappedValue = ""
        }
    }

    private func configureSearchControllerIfNeeded() {
        guard let hostController = hostingController() else { return }
        owningController = hostController
        let ownerID = ObjectIdentifier(hostController)
        searchController.searchBar.placeholder = promptText
        syncSearchBarText()

        if configuredOwnerID == ownerID,
           hostController.navigationItem.searchController === searchController {
            return
        }

        configureWorkItem?.cancel()
        hostController.navigationItem.searchController = nil

        let workItem = DispatchWorkItem { [weak self, weak hostController] in
            guard let self = self, let hostController = hostController else { return }
            self.owningController = hostController
            hostController.definesPresentationContext = true
            hostController.navigationItem.hidesSearchBarWhenScrolling = true
            if #available(iOS 16.0, *) {
                hostController.navigationItem.preferredSearchBarPlacement = .stacked
            }
            hostController.navigationItem.searchController = self.searchController
            self.searchController.isActive = false
            self.searchController.searchBar.placeholder = self.promptText
            self.syncSearchBarText()
            self.configuredOwnerID = ownerID
        }

        configureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func detachSearchControllerIfNeeded() {
        configureWorkItem?.cancel()
        configuredOwnerID = nil
        guard let owner = owningController, owner.navigationItem.searchController === searchController else { return }
        owner.navigationItem.searchController = nil
    }

    private func syncSearchBarText() {
        let currentText = searchController.searchBar.text ?? ""
        if currentText != textBinding.wrappedValue {
            searchController.searchBar.text = textBinding.wrappedValue
        }
    }

    private func hostingController() -> UIViewController? {
        var current = parent
        while let controller = current {
            if controller.navigationController != nil {
                return controller
            }
            current = controller.parent
        }
        return parent
    }
}

final class SafeAreaInsetObservingView: UIView {
    var onChange: ((UIEdgeInsets) -> Void)?
    private var lastInsets: UIEdgeInsets?

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportSafeAreaIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportSafeAreaIfNeeded()
    }

    func reportSafeAreaIfNeeded(force: Bool = false) {
        let insets = safeAreaInsets
        guard force || lastInsets == nil || lastInsets != insets else { return }
        lastInsets = insets
        onChange?(insets)
    }
}

/// Unified close button for fullScreenCover presentations.
/// Displays a circular semi-transparent dark button with a white "xmark" icon.
struct FullScreenCloseButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundColor(.white)
        }
    }
}

struct PreviewDismissHandle: View {
    let onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(UIColor.tertiaryLabel).opacity(0.85))
            .frame(width: 42, height: 5)
            .padding(.vertical, 10)
            .padding(.horizontal, 24)
            .background(Color(UIColor.secondarySystemBackground).opacity(0.92))
            .clipShape(Capsule())
            .offset(y: max(0, dragOffset * 0.18))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        guard value.translation.height > 0, abs(value.translation.width) < 80 else {
                            dragOffset = 0
                            return
                        }
                        dragOffset = min(value.translation.height, 80)
                    }
                    .onEnded { value in
                        let shouldDismiss = value.translation.height > 44 && abs(value.translation.width) < 80
                        dragOffset = 0
                        if shouldDismiss {
                            onDismiss()
                        }
                    }
            )
            .accessibilityLabel(Text(NSLocalizedString("Close Preview", comment: "")))
            .accessibilityAddTraits(.isButton)
    }
}

// A generic enforcer that hooks into UIKit lifecycle
struct TabVisibilityEnforcer: UIViewControllerRepresentable {
    let hidden: Bool
    
    func makeUIViewController(context: Context) -> TabVisibilityViewController {
        let vc = TabVisibilityViewController()
        vc.shouldHideTabBar = hidden
        return vc
    }
    
    func updateUIViewController(_ uiView: TabVisibilityViewController, context: Context) {
        uiView.shouldHideTabBar = hidden
        // Force update if needed? Usually viewWillAppear handles it.
    }
}

struct TabBarLocalizationConfigurator: UIViewControllerRepresentable {
    let refreshKey: String
    let titles: [String]

    func makeUIViewController(context: Context) -> TabBarLocalizationViewController {
        let viewController = TabBarLocalizationViewController()
        viewController.refreshKey = refreshKey
        viewController.titles = titles
        return viewController
    }

    func updateUIViewController(_ uiViewController: TabBarLocalizationViewController, context: Context) {
        uiViewController.refreshKey = refreshKey
        uiViewController.titles = titles
        uiViewController.applyLocalizedTitlesIfNeeded()
    }
}

class TabVisibilityViewController: UIViewController {
    var shouldHideTabBar: Bool = false
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Access Tab Bar
        updateTabBarVisibility(hidden: shouldHideTabBar)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // If we are hiding it, we should restore it when we disappear (pop back)
        // But only if we are popping? 
        // If we are pushing deeper, we might want to keep it hidden.
        // Simplified Logic: If we are currently "Hiding" it, then on disappear we "Show" it (restore).
        // If the next view wants to hide it, it will hide it on IT'S viewWillAppear.
        // This causes a potential flicker but ensures restoration.
        
        if shouldHideTabBar {
            updateTabBarVisibility(hidden: false)
        }
    }
    
    private func updateTabBarVisibility(hidden: Bool) {
        guard let tabController = self.findTabBarController() else { return }
        
        // Avoid redundant setting to prevent animation glitches
        if tabController.tabBar.isHidden != hidden {
            // Use animation for smoother transition if desired, or false for instant snapping (User prefers instant usually)
            // On iOS 18, better to match the transition.
            
            // Standard behavior: Changing isHidden is instant. layoutIfNeeded accounts for frame.
            tabController.tabBar.isHidden = hidden
        }
    }
    
    func findTabBarController() -> UITabBarController? {
        if let tabController = self.tabBarController {
            return tabController
        }
        var parent = self.parent
        while parent != nil {
            if let tabController = parent?.tabBarController {
                return tabController
            }
            parent = parent?.parent
        }
        return nil
    }
}

class TabBarLocalizationViewController: UIViewController {
    var refreshKey: String = ""
    var titles: [String] = []
    private var lastAppliedSignature: String = ""

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyLocalizedTitlesIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLocalizedTitlesIfNeeded()
    }

    func applyLocalizedTitlesIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let tabController = self.findTabBarController() else { return }

            let signature = self.refreshKey + "|" + self.titles.joined(separator: "|")
            guard signature != self.lastAppliedSignature else { return }

            let viewControllers = tabController.viewControllers ?? []
            let items = tabController.tabBar.items ?? []

            for (index, title) in self.titles.enumerated() {
                if index < viewControllers.count {
                    viewControllers[index].tabBarItem.title = title
                }
                if index < items.count {
                    items[index].title = title
                }
            }

            self.lastAppliedSignature = signature
            tabController.tabBar.setNeedsLayout()
            tabController.tabBar.layoutIfNeeded()
        }
    }

    private func findTabBarController() -> UITabBarController? {
        if let tabController = self.tabBarController {
            return tabController
        }

        var parent = self.parent
        while parent != nil {
            if let tabController = parent?.tabBarController {
                return tabController
            }
            parent = parent?.parent
        }

        return nil
    }
}

#endif

#endif
struct ConnectionProgressOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var subtitle: String? = nil
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.16)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    Text(NSLocalizedString("Tap to cancel", comment: ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 228)
            .background(
                ZStack {
                    VisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                    Color.black.opacity(0.2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.1), lineWidth: 0.9)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.12), radius: 16, x: 0, y: 8)
            .padding(.horizontal, 24)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture(perform: onCancel)
        }
    }
}

private struct PrivacyProtectedContentModifier: ViewModifier {
    let title: String
    let isProtected: Bool

    @ObservedObject private var securityService = SecurityService.shared
    @State private var isShowingUnlockSheet = false

    private var computedProtected: Bool {
        isProtected && securityService.isPrivacySpaceEnabled && !securityService.isPrivacySpaceUnlocked
    }

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(computedProtected)
                .blur(radius: computedProtected ? 14 : 0)

            if computedProtected {
                PrivacyProtectionOverlay(
                    title: title,
                    onUnlock: { isShowingUnlockSheet = true }
                )
            }
        }
        .sheet(isPresented: $isShowingUnlockSheet) {
            PrivacySpaceUnlockView(
                isPresented: $isShowingUnlockSheet,
                title: title
            )
        }
    }
}

private struct PrivacyProtectionOverlay: View {
    let title: String
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.primary)

                VStack(spacing: 6) {
                    Text(NSLocalizedString("Privacy Space Locked", comment: ""))
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text(
                        String(
                            format: NSLocalizedString("Unlock Privacy Space to access \"%@\" and all protected content.", comment: ""),
                            title
                        )
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                }

                Button(action: onUnlock) {
                    Text(NSLocalizedString("Unlock Privacy Space", comment: ""))
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(minWidth: 220)
                        .background(Color(UIColor.systemBlue))
                        .cornerRadius(14)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(18)
            .padding(.horizontal, 24)
        }
    }
}

struct PrivacySpaceUnlockView: View {
    @Binding var isPresented: Bool
    let title: String
    var onSuccess: (() -> Void)? = nil

    @ObservedObject private var securityService = SecurityService.shared
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var hasAutoPromptedBiometrics = false

    var body: some View {
        #if os(tvOS)
        tvUnlockPanel
            .onAppear {
                autoPromptBiometricsIfNeeded()
            }
        #elseif os(macOS)
        macUnlockPanel
            .onAppear {
                autoPromptBiometricsIfNeeded()
            }
        #else
        mobileUnlockForm
            .onAppear {
                autoPromptBiometricsIfNeeded()
            }
        #endif
    }

    #if os(tvOS)
    private var tvUnlockPanel: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(UIColor.systemBlue).opacity(0.88))
                            .frame(width: 58, height: 58)

                        Image(systemName: "lock.fill")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .shadow(color: Color(UIColor.systemBlue).opacity(0.28), radius: 18, x: 0, y: 10)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("Unlock Privacy Space", comment: ""))
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(
                            String(
                                format: NSLocalizedString("Enter the privacy password to access \"%@\".", comment: ""),
                                title
                            )
                        )
                        .font(.system(size: 23, weight: .regular))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(NSLocalizedString("Privacy Password", comment: ""))
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))

                    tvSecureField
                }

                Text(errorMessage.isEmpty ? " " : errorMessage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(errorMessage.isEmpty ? .clear : Color(UIColor.systemRed))
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 18) {
                    Button(action: submitPassword) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(size: 20, weight: .semibold))
                            Text(NSLocalizedString("Unlock", comment: ""))
                                .font(.system(size: 22, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(width: 210, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(UIColor.systemBlue))
                        )
                    }

                    Button(action: {
                        isPresented = false
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "xmark")
                                .font(.system(size: 19, weight: .semibold))
                            Text(NSLocalizedString("Cancel", comment: ""))
                                .font(.system(size: 22, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(0.86))
                        .frame(width: 180, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.13))
                        )
                    }

                    if securityService.shouldShowPrivacyBiometricUnlock {
                        Button(action: triggerBiometricUnlock) {
                            HStack(spacing: 10) {
                                Image(systemName: securityService.biometricIconName)
                                Text(securityService.biometricsSettingTitle)
                            }
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white.opacity(0.86))
                            .frame(height: 64)
                            .padding(.horizontal, 24)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 40)
            .frame(width: 680)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.42), radius: 46, x: 0, y: 28)
        }
        .onExitCommand {
            isPresented = false
        }
    }

    @ViewBuilder
    private var tvSecureField: some View {
        if securityService.isSimplePrivacyPassword {
            SecureField(NSLocalizedString("Enter 4-digit PIN", comment: ""), text: $password, onCommit: submitPassword)
                .keyboardType(.numberPad)
                .onChange(of: password, perform: handleSimplePasswordChange)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .frame(height: 68)
                .background(tvFieldBackground)
        } else {
            SecureField(NSLocalizedString("Enter Password", comment: ""), text: $password, onCommit: submitPassword)
                .keyboardType(.default)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .frame(height: 68)
                .background(tvFieldBackground)
        }
    }

    private var tvFieldBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }
    #endif

    #if os(macOS)
    private var macUnlockPanel: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text(platformShellString("Privacy Space Locked"))
                    .font(.title2.weight(.semibold))

                Text(String(format: platformShellString("Unlock Privacy Space to access \"%@\" and all protected content."), title))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(platformShellString("Privacy Password"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if securityService.isSimplePrivacyPassword {
                    SecureField(platformShellString("Enter 4-digit PIN"), text: $password, onCommit: submitPassword)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: password, perform: handleSimplePasswordChange)
                } else {
                    SecureField(platformShellString("Enter Password"), text: $password, onCommit: submitPassword)
                        .textFieldStyle(.roundedBorder)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
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

                if securityService.shouldShowPrivacyBiometricUnlock {
                    Button(action: triggerBiometricUnlock) {
                        Image(systemName: securityService.biometricIconName)
                    }
                    .buttonStyle(.bordered)
                    .help(securityService.biometricsSettingTitle)
                }
            }
        }
        .padding(32)
        .frame(width: 400)
    }
    #endif

    private var mobileUnlockForm: some View {
        NavigationView {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(Color(UIColor.systemBlue))
                            .padding(.top, 6)

                        Text(NSLocalizedString("Privacy Space Locked", comment: ""))
                            .font(.headline)

                        Text(
                            String(
                                format: NSLocalizedString("Unlock Privacy Space to access \"%@\" and all protected content.", comment: ""),
                                title
                            )
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section(header: Text(NSLocalizedString("Privacy Password", comment: ""))) {
                    if securityService.isSimplePrivacyPassword {
                        SecureField(NSLocalizedString("Enter 4-digit PIN", comment: ""), text: $password, onCommit: submitPassword)
                            .keyboardType(.numberPad)
                            .onChange(of: password, perform: handleSimplePasswordChange)
                    } else {
                        SecureField(NSLocalizedString("Enter Password", comment: ""), text: $password, onCommit: submitPassword)
                            .keyboardType(.default)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button(action: submitPassword) {
                        HStack {
                            Spacer()
                            Text(NSLocalizedString("Unlock", comment: ""))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }

                    if securityService.shouldShowPrivacyBiometricUnlock {
                        Button(action: triggerBiometricUnlock) {
                            HStack {
                                Image(systemName: securityService.biometricIconName)
                                Text(securityService.biometricsSettingTitle)
                            }
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Privacy Space", comment: ""))
            .navigationBarItems(
                leading: Button(action: {
                    isPresented = false
                }) {
                    AppToolbarIcon(systemName: "xmark", style: .secondary)
                }
            )
        }
        .navigationViewStyle(.stack)
    }

    private func autoPromptBiometricsIfNeeded() {
        guard !hasAutoPromptedBiometrics else { return }
        guard securityService.shouldShowPrivacyBiometricUnlock else { return }
        hasAutoPromptedBiometrics = true
        triggerBiometricUnlock()
    }

    private func handleSimplePasswordChange(_ newValue: String) {
        let filtered = newValue.filter { "0123456789".contains($0) }
        let normalized = String(filtered.prefix(4))

        if normalized != newValue {
            password = normalized
            return
        }

        if !errorMessage.isEmpty {
            errorMessage = ""
        }

        if normalized.count == 4 {
            submitPassword()
        }
    }

    private func submitPassword() {
        errorMessage = ""
        if securityService.unlockPrivacySpace(with: password) {
            isPresented = false
            onSuccess?()
        } else {
            errorMessage = NSLocalizedString("Incorrect privacy password. Try again.", comment: "")
        }
    }

    private func triggerBiometricUnlock() {
        errorMessage = ""
        securityService.authenticateForPrivacy { success in
            if success {
                isPresented = false
                onSuccess?()
            } else if !securityService.allowBiometricsForPrivacy {
                errorMessage = securityService.biometricsUnavailableMessage()
            }
        }
    }
}

extension View {
    func privacyProtectedContent(title: String, isProtected: Bool) -> some View {
        modifier(PrivacyProtectedContentModifier(title: title, isProtected: isProtected))
    }
}

#if targetEnvironment(macCatalyst) || os(macOS)
struct MacCardHoverEffect: ViewModifier {
    var cornerRadius: CGFloat
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.3 : 0.0), lineWidth: isHovered ? 2 : 0)
            )
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .shadow(color: Color.black.opacity(isHovered ? 0.4 : 0.0), radius: isHovered ? 12 : 0, x: 0, y: isHovered ? 6 : 0)
            .zIndex(isHovered ? 1 : 0)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isHovered = hovering
                        }
                    }
            )
    }
}

struct MacButtonHoverEffect: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .overlay(
                Color.primary.opacity(isHovered ? 0.1 : 0.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }
}

struct MacPosterHoverPlayOverlay: View {
    let isCardHovered: Bool
    let onPlay: (() -> Void)?
    var buttonSize: CGFloat = 44
    var cornerRadius: CGFloat = 8

    @State private var isPlayButtonHovered = false

    var body: some View {
        if isCardHovered, let onPlay = onPlay {
            ZStack {
                Color.black.opacity(0.35)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)

                Button(action: onPlay) {
                    ZStack {
                        Circle()
                            .fill(isPlayButtonHovered ? Color(red: 0.0, green: 0.64, blue: 0.86) : Color.black.opacity(0.65))
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(isPlayButtonHovered ? 0.7 : 0.35), lineWidth: 1.2)
                            )

                        Image(systemName: "play.fill")
                            .font(.system(size: buttonSize * 0.42, weight: .bold))
                            .foregroundColor(.white)
                            .offset(x: 1.5)
                    }
                    .frame(width: buttonSize, height: buttonSize)
                    .scaleEffect(isPlayButtonHovered ? 1.08 : 1.0)
                    .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
                    .contentShape(Circle())
                }
                .buttonStyle(BorderlessButtonStyle()) // Crucial for independent clicking inside NavigationLink
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isPlayButtonHovered = hovering
                    }
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
    }
}

extension View {
    func macCardHoverEffect(cornerRadius: CGFloat = 12) -> some View {
        self.modifier(MacCardHoverEffect(cornerRadius: cornerRadius))
    }
    
    func macButtonHoverEffect() -> some View {
        self.modifier(MacButtonHoverEffect())
    }
}
#else
extension View {
    func macCardHoverEffect(cornerRadius: CGFloat = 12) -> some View {
        self
    }
    
    func macButtonHoverEffect() -> some View {
        self
    }
}
#endif


private struct ScrollContentBackgroundCompatModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content.onAppear {
                UITableView.appearance().backgroundColor = .clear
            }
        }
    }
}

extension View {
    func scrollContentBackgroundCompatHidden() -> some View {
        modifier(ScrollContentBackgroundCompatModifier())
    }
}

private struct NavigationBarBackgroundHiddenModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
                .scrollEdgeEffectHidden(true, for: .top)
        } else if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
        #else
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
        #endif
    }
}

extension View {
    func hideNavigationBarBackground() -> some View {
        self.modifier(NavigationBarBackgroundHiddenModifier())
    }
}
