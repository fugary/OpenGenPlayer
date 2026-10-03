import SwiftUI
#if os(iOS)
import UIKit
#endif

struct MediaHomeCarouselItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let metadataSegments: [String]
    let overview: String?
    let sourceTitle: String
    let sourceSystemImage: String?
    let imageURL: URL?
    let backdropImageURL: URL?
    let portraitImageURL: URL?
    let logoURLs: [URL]?
    let actionTitle: String
    let actionSystemImage: String
    let playbackProgress: PlaybackProgressSnapshot?
}

enum MediaHomeSpotlightFamily: Equatable {
    case movie
    case series
    case other
}

func mediaHomeSpotlightFamily(forItemType type: String) -> MediaHomeSpotlightFamily {
    switch type.lowercased() {
    case "movie":
        return .movie
    case "series", "show", "season", "episode":
        return .series
    default:
        return .other
    }
}

func mediaHomePreferredSpotlightFamily(from itemTypes: [String]) -> MediaHomeSpotlightFamily? {
    for type in itemTypes {
        let family = mediaHomeSpotlightFamily(forItemType: type)
        if family != .other {
            return family
        }
    }
    return nil
}

struct MediaHomeCarouselView: View {
    let items: [MediaHomeCarouselItem]
    var onSelect: (MediaHomeCarouselItem) -> Void
    var onAction: (MediaHomeCarouselItem) -> Void
    var pausesWhenInactive: Bool
    var isActive: Bool
    @State private var isHovered = false
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection = 0
    @State private var availableWidth: CGFloat = 0
    @State private var windowLayout = WindowLayoutMetrics()
    @StateObject private var backdropReadability = AdaptiveBackdropReadabilityModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let autoAdvanceTimer = Timer.publish(every: 6.0, on: .main, in: .common).autoconnect()

    init(
        items: [MediaHomeCarouselItem],
        pausesWhenInactive: Bool = false,
        isActive: Bool = true,
        onSelect: @escaping (MediaHomeCarouselItem) -> Void,
        onAction: ((MediaHomeCarouselItem) -> Void)? = nil
    ) {
        self.items = items
        self.pausesWhenInactive = pausesWhenInactive
        self.isActive = isActive
        self.onSelect = onSelect
        self.onAction = onAction ?? onSelect
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                carouselBody
                .onAppear { isVisible = true }
                .onDisappear { isVisible = false }
                .onHover { isHovered = $0 }
                .background(WindowLayoutReader { windowLayout = $0 })
                .onWidthChange { width in
                    availableWidth = width
                }
                .onReceive(autoAdvanceTimer) { _ in
                    advanceIfNeeded()
                }
                .onChange(of: items.map { $0.id }) { _ in
                    clampSelection()
                }
                .onChange(of: selectedCarouselItem?.id) { _ in
                    backdropReadability.reset()
                }
            }
        }
    }

    @ViewBuilder
    private var carouselBody: some View {
        if usesFullScreenBackdropHero {
            detailStyleCarousel
        } else {
            regularCarousel
        }
    }

    private var regularCarousel: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let height = carouselHeight(for: proxy.size.width)

                ZStack {
                    TabView(selection: $selection) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            slide(for: item, height: height)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                    if items.count > 1 {
                        carouselControls
                            .padding(.trailing, controlsTrailingPadding)
                            .padding(.bottom, controlsBottomPadding)
                            .padding(.top, controlsTopPadding)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: controlsAlignment)
                    }
                }
            }
            .frame(height: carouselHeight(for: availableWidth))
        }
        .padding(.horizontal, carouselHorizontalPadding)
        .padding(.top, carouselTopAdjustment)
    }

    private var detailStyleCarousel: some View {
        GeometryReader { proxy in
            let height = carouselHeight(for: proxy.size.width)
            let isLandscapeOrWide = horizontalSizeClass == .regular || proxy.size.width > 600

            ZStack(alignment: .topLeading) {
                Color.black

                TabView(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        detailStyleSlide(for: item, width: proxy.size.width, height: height)
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                if let selectedItem = selectedCarouselItem {
                    // Top-Right ClearLogo Overlay (Only for Landscape / Wide screens: iPad or iPhone Landscape)
                    if isLandscapeOrWide, let logoUrl = selectedItem.logoURLs?.first {
                        let isPad = horizontalSizeClass == .regular
                        let fallbackInset: CGFloat = isPad ? 54 : 47
                        let topInset = windowLayout.size == .zero ? fallbackInset : windowLayout.safeAreaInsets.top

                        VStack {
                            HStack {
                                Spacer()

                                RemoteLogoImage(url: logoUrl, maxHeight: isPad ? 72 : 50)
                                    .shadow(color: .black.opacity(0.65), radius: 8, x: 0, y: 4)
                                    .padding(.top, topInset + (isPad ? 76 : 36))
                                    .padding(.trailing, (isPad ? 76 : 56) + windowLayout.safeAreaInsets.right)
                            }
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }

                    detailStyleContentOverlay(
                        for: selectedItem,
                        width: max(0, proxy.size.width - windowLayout.safeAreaInsets.left - windowLayout.safeAreaInsets.right),
                        height: height
                    )
                    .padding(.leading, windowLayout.safeAreaInsets.left)
                    .padding(.trailing, windowLayout.safeAreaInsets.right)
                }
            }
        }
        .frame(height: carouselHeight(for: availableWidth))
        .background(Color.black)
        .edgesIgnoringSafeArea([.top, .horizontal])
    }

    private func slide(for item: MediaHomeCarouselItem, height: CGFloat) -> some View {
        let showsOverview = showsOverview(for: height)

        return ZStack(alignment: .bottomLeading) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(
                    url: regularImageURL(for: item),
                    placeholderSystemImage: "play.rectangle.fill",
                    placeholderTint: .white.opacity(0.75),
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }

            Color.black.opacity(0.08)
                .allowsHitTesting(false)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.90),
                    Color.black.opacity(0.62),
                    Color.black.opacity(0.18),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .allowsHitTesting(false)

            LinearGradient(
                colors: bottomScrimColors,
                startPoint: UnitPoint(x: 0.5, y: 0.18),
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            Button(action: {
                onSelect(item)
            }) {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            regularContent(for: item, height: height, showsOverview: showsOverview)

            regularActionButton(for: item)
                .padding(.trailing, contentHorizontalPadding)
                .padding(.bottom, contentBottomPadding(for: height))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(height: height)
        .cornerRadius(carouselCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: carouselCornerRadius)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: carouselCornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(NSLocalizedString("View Details", comment: "")): \(item.title)"))
    }

    private func detailStyleBackdrop(
        for item: MediaHomeCarouselItem,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack(alignment: .top) {
            RemoteImage(
                url: backdropImageURL(for: item),
                placeholderSystemImage: "play.rectangle.fill",
                placeholderTint: .white.opacity(0.58),
                contentMode: .fill,
                onImageLoaded: { image in
                    backdropReadability.update(from: image)
                }
            )
            .scaleEffect(1.12, anchor: .top)
            .frame(width: width, height: height, alignment: .top)
            .clipped()
            .blur(radius: 34)
            .overlay(Color.black.opacity(ambientBackdropOverlayOpacity))

            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(
                        url: backdropImageURL(for: item),
                        placeholderSystemImage: "play.rectangle.fill",
                        placeholderTint: .white.opacity(0.58),
                        contentMode: .fill
                    )
                    .scaleEffect(1.06, anchor: .top)
                    .frame(width: width, height: detailBackdropHeaderHeight(for: height), alignment: .top)
                    .clipped()
                    .overlay(detailHeaderGradient)
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.68),
                                .init(color: .black.opacity(0.74), location: 0.88),
                                .init(color: .clear, location: 1.0)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                Spacer(minLength: 0)
            }

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.black.opacity(0.72), location: 0.0),
                    .init(color: Color.black.opacity(0.38), location: 0.45),
                    .init(color: Color.clear, location: 0.85)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .allowsHitTesting(false)

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.clear, location: 0.0),
                    .init(color: Color.black.opacity(0.06), location: 0.36),
                    .init(color: Color.black.opacity(0.28), location: 0.74),
                    .init(color: Color(UIColor.systemBackground).opacity(0.78), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var detailHeaderGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(backdropReadability.style.heroTopOpacity),
                Color.black.opacity(backdropReadability.style.heroUpperMidOpacity),
                Color.black.opacity(backdropReadability.style.heroLowerMidOpacity),
                Color.black.opacity(backdropReadability.style.heroBottomOpacity)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var ambientBackdropOverlayOpacity: Double {
        max(0.34, backdropReadability.style.baseOverlayOpacity - 0.12)
    }

    private func detailStyleSlide(
        for item: MediaHomeCarouselItem,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            detailStyleBackdrop(for: item, width: width, height: height)
                .frame(width: width, height: height)

            Button(action: {
                onSelect(item)
            }) {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(NSLocalizedString("View Details", comment: "")): \(item.title)"))
    }

    private func detailStyleContentOverlay(
        for item: MediaHomeCarouselItem,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let isLandscapeOrWide = horizontalSizeClass == .regular || width > 600
        let alignment: HorizontalAlignment = isLandscapeOrWide ? .leading : .center
        let textAlignment: TextAlignment = isLandscapeOrWide ? .leading : .center
        let frameAlignment: Alignment = isLandscapeOrWide ? .bottomLeading : .bottom

        return VStack(spacing: 0) {
            // Flexible spacer that pushes content to the bottom of the padded area
            Spacer(minLength: 0)

            VStack(alignment: alignment, spacing: spotlightContentSpacing(for: height)) {
                // iPhone Portrait: render ClearLogo above Title inside content overlay
                if !isLandscapeOrWide, let logoUrl = item.logoURLs?.first {
                    RemoteLogoImage(url: logoUrl, maxHeight: 38)
                        .shadow(color: Color.black.opacity(0.60), radius: 8, x: 0, y: 3)
                        .padding(.bottom, 6)
                }

                VStack(alignment: alignment, spacing: 4) {
                    Text(spotlightPrimaryTitle(for: item))
                        .font(.system(size: spotlightTitleFontSize(for: height), weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                        .multilineTextAlignment(textAlignment)
                        .shadow(color: Color.black.opacity(0.85), radius: 10, x: 0, y: 4)

                    if let secondary = spotlightSecondaryTitle(for: item), !secondary.isEmpty {
                        Text(secondary)
                            .font(spotlightSecondaryTitleFont(for: height))
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                            .multilineTextAlignment(textAlignment)
                    }
                }

                metadataText(for: item, height: height, alignment: textAlignment)

                // Show the synopsis when the current layout has regular width.
                if horizontalSizeClass == .regular {
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(spotlightOverviewFont(for: height))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(verticalSizeClass == .compact ? 2 : 2)
                            .minimumScaleFactor(0.82)
                            .multilineTextAlignment(textAlignment)
                            .padding(.top, 2)
                    }
                }

                Button(action: {
                    onAction(item)
                }) {
                    detailStyleActionChip(for: item)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(Text(detailStyleActionTitle(for: item)))
                .frame(height: spotlightActionRowHeight, alignment: frameAlignment)
                .padding(.top, 10)

                if items.count > 1 {
                    compactPageIndicator
                        .frame(height: spotlightIndicatorHeight, alignment: frameAlignment)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: isLandscapeOrWide ? spotlightContentMaxWidth : .infinity, alignment: frameAlignment)
            .padding(.horizontal, spotlightHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .id(item.id)
            .animation(.easeInOut(duration: 0.18), value: item.id)
        }
        .padding(.top, spotlightTopReserveHeight)
        .padding(.bottom, spotlightBottomPadding(for: height))
        .frame(width: width, height: height)
    }

    private func detailStyleActionChip(for item: MediaHomeCarouselItem) -> some View {
        let progress = activePlaybackProgress(for: item)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.92))

            if let progress {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.20))
                        .frame(width: geo.size.width * CGFloat(progress.displayedProgress))
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: spotlightActionButtonWidth, height: spotlightActionButtonHeight)
        .overlay(
            Capsule()
                .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
        )
        .overlay(
            HStack(spacing: 8) {
                Image(systemName: item.actionSystemImage)
                    .font(.system(size: 15, weight: .bold))

                Text(detailStyleActionTitle(for: item))
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(1)

                if let progress {
                    Text("\(Int(progress.displayedProgress * 100))%")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(.black.opacity(0.86))
            .padding(.horizontal, 18)
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.14), radius: 9, x: 0, y: 4)
    }

    private func regularActionButton(for item: MediaHomeCarouselItem) -> some View {
        Button(action: {
            onAction(item)
        }) {
            HStack(spacing: 7) {
                Image(systemName: item.actionSystemImage)
                    .font(.system(size: 12, weight: .bold))

                Text(detailStyleActionTitle(for: item))
                    .font(.caption)
                    .fontWeight(.bold)
                    .lineLimit(1)
            }
            .foregroundColor(.black.opacity(0.86))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Color.white.opacity(0.92))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 7, x: 0, y: 3)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text(detailStyleActionTitle(for: item)))
    }

    private func detailStyleActionBottomOffset(for height: CGFloat) -> CGFloat {
        let indicatorReserve = items.count > 1 ? spotlightIndicatorHeight + 12 : 0
        return spotlightBottomPadding(for: height) + indicatorReserve
    }

    private func activePlaybackProgress(for item: MediaHomeCarouselItem) -> PlaybackProgressSnapshot? {
        guard let progress = item.playbackProgress,
              progress.displayedProgress > 0,
              !progress.isFinished else {
            return nil
        }
        return progress
    }

    private func detailStyleActionTitle(for item: MediaHomeCarouselItem) -> String {
        if let progress = item.playbackProgress,
           progress.displayedProgress > 0,
           !progress.isFinished,
           item.actionSystemImage == "play.fill" {
            return NSLocalizedString("Continue", comment: "")
        }
        return item.actionTitle
    }

    private func regularContent(
        for item: MediaHomeCarouselItem,
        height: CGFloat,
        showsOverview: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing(for: height)) {
            sourceRow(for: item, height: height)

            if let logoUrl = item.logoURLs?.first {
                RemoteLogoImage(url: logoUrl, maxHeight: 42)
                    .shadow(color: Color.black.opacity(0.54), radius: 10, x: 0, y: 4)
            } else {
                titleText(for: item, height: height, alignment: .leading)
            }

            metadataText(for: item, height: height, alignment: .leading)

            if let overview = item.overview, !overview.isEmpty, showsOverview {
                Text(overview)
                    .font(overviewFont(for: height))
                    .foregroundColor(.white.opacity(0.84))
                    .lineLimit(overviewLineLimit(for: height))
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.leading, contentHorizontalPadding)
        .padding(.trailing, contentHorizontalPadding + trailingSafeContentPadding)
        .padding(.bottom, contentBottomPadding(for: height))
        .padding(.top, 18)
        .frame(maxWidth: contentMaxWidth, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private func compactContent(
        for item: MediaHomeCarouselItem,
        height: CGFloat,
        showsOverview: Bool
    ) -> some View {
        VStack(alignment: .center, spacing: contentSpacing(for: height)) {
            if let logoUrl = item.logoURLs?.first {
                RemoteLogoImage(url: logoUrl, maxHeight: 36)
                    .shadow(color: Color.black.opacity(0.54), radius: 10, x: 0, y: 4)
            } else {
                titleText(for: item, height: height, alignment: .center)
            }

            metadataText(for: item, height: height, alignment: .center)

            if let progress = item.playbackProgress {
                compactProgressPill(for: progress, height: height)
                    .padding(.top, 2)
            }

            if let overview = item.overview, !overview.isEmpty, showsOverview {
                Text(overview)
                    .font(overviewFont(for: height))
                    .foregroundColor(.white.opacity(0.84))
                    .lineLimit(overviewLineLimit(for: height))
                    .multilineTextAlignment(.center)
            }

            if items.count > 1 {
                compactPageIndicator
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.bottom, contentBottomPadding(for: height))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private func titleText(
        for item: MediaHomeCarouselItem,
        height: CGFloat,
        alignment: TextAlignment
    ) -> some View {
        Text(item.title)
            .font(.system(size: titleFontSize(for: height), weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .multilineTextAlignment(alignment)
            .shadow(color: Color.black.opacity(0.42), radius: 10, x: 0, y: 4)
    }

    @ViewBuilder
    private func metadataText(
        for item: MediaHomeCarouselItem,
        height: CGFloat,
        alignment: TextAlignment
    ) -> some View {
        if !item.metadataSegments.isEmpty {
            Text(item.metadataSegments.joined(separator: "  •  "))
                .font(metadataFont(for: height))
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.86))
                .lineLimit(usesImmersiveCompactHero ? 1 : 2)
                .minimumScaleFactor(0.78)
                .multilineTextAlignment(alignment)
        } else if let subtitle = item.subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(metadataFont(for: height))
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .multilineTextAlignment(alignment)
        }
    }

    private func compactTopSourceBadge(for item: MediaHomeCarouselItem) -> some View {
        VStack {
            HStack {
                sourceBadge(for: item)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.top, compactTopBadgePadding)
        .allowsHitTesting(false)
    }

    private var carouselControls: some View {
        HStack(spacing: 10) {
            carouselControlButton(systemName: "chevron.left", action: moveToPrevious)

            HStack(spacing: 8) {
                pageIndicator

                Text("\(selection + 1) / \(items.count)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.heavy)
                    .foregroundColor(.white.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.black.opacity(0.44))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
            )

            carouselControlButton(systemName: "chevron.right", action: moveToNext)
        }
        .accessibilityHidden(true)
    }

    private var pageIndicator: some View {
        pageIndicator(activeColor: Color.accentColor.opacity(0.95), inactiveColor: Color.white.opacity(0.30))
    }

    private var compactPageIndicator: some View {
        pageIndicator(activeColor: Color.white.opacity(0.96), inactiveColor: Color.white.opacity(0.36))
    }

    private func pageIndicator(activeColor: Color, inactiveColor: Color) -> some View {
        HStack(spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                Circle()
                    .fill(index == selection ? activeColor : inactiveColor)
                    .frame(width: index == selection ? 8 : 6, height: index == selection ? 8 : 6)
            }
        }
    }

    private func carouselControlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(.white.opacity(0.88))
                .frame(width: 42, height: 42)
                .background(Color.black.opacity(0.46))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func sourceRow(for item: MediaHomeCarouselItem, height: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 8) {
            sourceBadge(for: item)

            if let progress = item.playbackProgress {
                PlaybackProgressBadge(
                    snapshot: progress,
                    diameter: progressBadgeSize(for: height),
                    usesDarkBackground: true,
                    symbolName: "play.fill",
                    finishedSymbolName: "checkmark",
                    symbolSize: progressSymbolSize(for: height)
                )

                Text("\(Int(progress.displayedProgress * 100))%")
                    .font(progressPercentFont(for: height))
                    .fontWeight(.heavy)
                    .foregroundColor(.white.opacity(0.74))
            }

            Spacer(minLength: 0)
        }
    }

    private func compactProgressPill(for progress: PlaybackProgressSnapshot, height: CGFloat) -> some View {
        HStack(spacing: 7) {
            PlaybackProgressBadge(
                snapshot: progress,
                diameter: progressBadgeSize(for: height),
                usesDarkBackground: true,
                symbolName: "play.fill",
                finishedSymbolName: "checkmark",
                symbolSize: progressSymbolSize(for: height)
            )

            Text("\(Int(progress.displayedProgress * 100))%")
                .font(progressPercentFont(for: height))
                .fontWeight(.heavy)
                .foregroundColor(.white.opacity(0.82))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.34))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
    }

    private func sourceBadge(for item: MediaHomeCarouselItem) -> some View {
        HStack(spacing: 6) {
            if let sourceSystemImage = item.sourceSystemImage {
                Image(systemName: sourceSystemImage)
                    .font(.system(size: sourceBadgeIconSize, weight: .bold))
            }

            Text(item.sourceTitle)
                .font(sourceBadgeFont)
                .fontWeight(.bold)
                .lineLimit(1)
        }
        .foregroundColor(Color.accentColor)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.38))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
            )
    }

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 680 : .infinity
    }

    private func contentSpacing(for height: CGFloat) -> CGFloat {
        if height < 360 { return 7 }
        return height >= 420 ? 12 : 9
    }

    private func carouselHeight(for width: CGFloat) -> CGFloat {
        AdaptiveMediaLayout.carouselHeight(
            width: width,
            windowSize: windowLayout.size,
            regularWidth: horizontalSizeClass == .regular,
            compactHeight: verticalSizeClass == .compact,
            immersive: usesFullScreenBackdropHero
        )
    }

    private var carouselHorizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? 24 : 0
    }

    private var carouselTopAdjustment: CGFloat {
        usesImmersiveCompactHero ? -8 : 0
    }

    private var carouselCornerRadius: CGFloat {
        horizontalSizeClass == .regular ? 14 : 0
    }

    private var contentHorizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? 34 : 22
    }

    private var trailingSafeContentPadding: CGFloat {
        horizontalSizeClass == .regular ? 210 : 0
    }

    private func contentBottomPadding(for height: CGFloat) -> CGFloat {
        if usesImmersiveCompactHero {
            return height >= 600 ? 72 : 54
        }

        if horizontalSizeClass == .regular {
            return height >= 400 ? 44 : 34
        }
        return 24
    }

    private var controlsTrailingPadding: CGFloat {
        horizontalSizeClass == .regular ? 34 : 16
    }

    private var controlsBottomPadding: CGFloat {
        horizontalSizeClass == .regular ? 34 : 18
    }

    private var controlsTopPadding: CGFloat {
        horizontalSizeClass == .regular ? 0 : 16
    }

    private var controlsAlignment: Alignment {
        horizontalSizeClass == .regular ? .bottomTrailing : .topTrailing
    }

    private func titleFontSize(for height: CGFloat) -> CGFloat {
        if usesImmersiveCompactHero {
            return height >= 600 ? 32 : 29
        }

        if horizontalSizeClass == .regular {
            if height < 360 { return 31 }
            return height >= 420 ? 42 : 35
        }
        return height >= 300 ? 31 : 27
    }

    private func metadataFont(for height: CGFloat) -> Font {
        if usesImmersiveCompactHero {
            return .subheadline
        }
        return horizontalSizeClass == .regular && height >= 390 ? .subheadline : .caption
    }

    private func overviewFont(for height: CGFloat) -> Font {
        horizontalSizeClass == .regular && height >= 420 ? .body : .subheadline
    }

    private func showsOverview(for height: CGFloat) -> Bool {
        if horizontalSizeClass == .regular { return true }
        if verticalSizeClass == .compact { return true }
        return height > 480
    }

    private func overviewLineLimit(for height: CGFloat) -> Int {
        if horizontalSizeClass == .regular {
            return height >= 420 ? 2 : 1
        }
        return height >= 320 ? 2 : 1
    }

    private var sourceBadgeFont: Font {
        usesImmersiveCompactHero || horizontalSizeClass == .regular ? .subheadline : .caption
    }

    private var sourceBadgeIconSize: CGFloat {
        usesImmersiveCompactHero || horizontalSizeClass == .regular ? 14 : 11
    }

    private func progressBadgeSize(for height: CGFloat) -> CGFloat {
        horizontalSizeClass == .regular && height >= 360 ? 28 : 22
    }

    private func progressSymbolSize(for height: CGFloat) -> CGFloat {
        horizontalSizeClass == .regular && height >= 360 ? 12 : 9
    }

    private func progressPercentFont(for height: CGFloat) -> Font {
        horizontalSizeClass == .regular && height >= 360 ? .headline : .caption
    }

    private var bottomScrimColors: [Color] {
        if usesImmersiveCompactHero {
            return [
                Color.clear,
                Color.black.opacity(0.12),
                Color.black.opacity(0.62),
                Color.black.opacity(0.86)
            ]
        }

        return [
            Color.clear,
            Color.black.opacity(0.28),
            Color.black.opacity(0.88)
        ]
    }

    private var compactTopBadgePadding: CGFloat {
        18
    }

    private var usesFullScreenBackdropHero: Bool {
        UIDevice.current.userInterfaceIdiom != .tv
    }

    private var usesImmersiveCompactHero: Bool {
        usesFullScreenBackdropHero
    }

    /// Minimum top reserve for the Spacer in detailStyleContentOverlay,
    /// ensuring content never creeps behind the floating navigation bar.
    private var spotlightTopReserveHeight: CGFloat {
        let isPad = horizontalSizeClass == .regular
        let safeAreaTop = windowLayout.safeAreaInsets.top
        // Fallback mainly for initial render in portrait if safeArea is 0
        let effectiveSafeAreaTop = (windowLayout.size == .zero && verticalSizeClass == .regular) ? (isPad ? 24 : 47) : safeAreaTop
        let navBarHeight: CGFloat = isPad ? 50 : 44
        let extraClearance: CGFloat = {
            if verticalSizeClass == .compact {
                return 8 // Landscape: clear nav bar, maximize content area
            }
            if isPad {
                return 40 // iPad: spacious clearance
            }
            return 28 // iPhone portrait: safe clearance below DS920plus badge
        }()
        return effectiveSafeAreaTop + navBarHeight + extraClearance
    }

    private var selectedCarouselItem: MediaHomeCarouselItem? {
        guard !items.isEmpty else { return nil }
        guard items.indices.contains(selection) else { return items.first }
        return items[selection]
    }

    private var spotlightContentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 720 : .infinity
    }

    private var spotlightHorizontalPadding: CGFloat {
        if verticalSizeClass == .compact {
            return 64
        }
        return horizontalSizeClass == .regular ? 76 : 24
    }

    private func spotlightBottomPadding(for height: CGFloat) -> CGFloat {
        if verticalSizeClass == .compact {
            return max(12, height * 0.04)
        }
        if horizontalSizeClass == .regular {
            if height < 500 { return 42 }
            return max(58, height * 0.11)
        }
        return max(42, height * 0.09)
    }

    private func spotlightContentSpacing(for height: CGFloat) -> CGFloat {
        if verticalSizeClass == .compact { return 6 }
        return horizontalSizeClass == .regular && height >= 560 ? 11 : 8
    }

    private func spotlightTitleFontSize(for height: CGFloat) -> CGFloat {
        if verticalSizeClass == .compact {
            return height >= 260 ? 30 : 26
        }
        if horizontalSizeClass == .regular {
            if height < 500 { return 48 }
            return height >= 620 ? 64 : 56
        }
        return height >= 520 ? 36 : 32
    }

    private func spotlightTitleSlotHeight(for height: CGFloat) -> CGFloat {
        if verticalSizeClass == .compact {
            return height >= 260 ? 64 : 54
        }
        if horizontalSizeClass == .regular {
            if height < 500 { return 96 }
            return height >= 620 ? 140 : 120
        }
        return height >= 520 ? 84 : 76
    }

    private func spotlightSecondaryTitleFont(for height: CGFloat) -> Font {
        horizontalSizeClass == .regular && height >= 560 ? .body : .subheadline
    }

    private func spotlightOverviewFont(for height: CGFloat) -> Font {
        horizontalSizeClass == .regular && height >= 560 ? .body : .caption
    }

    private var spotlightSecondaryTitleHeight: CGFloat {
        horizontalSizeClass == .regular ? 24 : 21
    }

    private var spotlightMetadataHeight: CGFloat {
        horizontalSizeClass == .regular ? 26 : 20
    }

    private func spotlightOverviewHeight(for height: CGFloat) -> CGFloat {
        if horizontalSizeClass == .regular {
            return height >= 620 ? 54 : 46
        }
        return height >= 520 ? 42 : 36
    }

    private var spotlightActionRowHeight: CGFloat {
        if verticalSizeClass == .compact { return 44 }
        return 50
    }

    private var spotlightActionButtonWidth: CGFloat {
        214
    }

    private var spotlightActionButtonHeight: CGFloat {
        58
    }

    private var spotlightIndicatorHeight: CGFloat {
        12
    }

    private func detailBackdropHeaderHeight(for height: CGFloat) -> CGFloat {
        horizontalSizeClass == .regular ? height * 1.04 : height * 0.98
    }

    private func regularImageURL(for item: MediaHomeCarouselItem) -> URL? {
        return item.imageURL ?? item.portraitImageURL
    }

    private func backdropImageURL(for item: MediaHomeCarouselItem) -> URL? {
        item.backdropImageURL ?? item.portraitImageURL ?? item.imageURL
    }

    private func posterImageURL(for item: MediaHomeCarouselItem) -> URL? {
        item.portraitImageURL ?? item.imageURL
    }

    private func spotlightPrimaryTitle(for item: MediaHomeCarouselItem) -> String {
        if let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subtitle.isEmpty,
           spotlightRemainderTitle(for: item.title, after: subtitle) != nil {
            return subtitle
        }
        return item.title
    }

    private func spotlightSecondaryTitle(for item: MediaHomeCarouselItem) -> String? {
        guard let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else {
            return nil
        }
        return spotlightRemainderTitle(for: item.title, after: subtitle)
    }

    private func spotlightOverviewText(for item: MediaHomeCarouselItem) -> String {
        item.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func spotlightRemainderTitle(for title: String, after prefix: String) -> String? {
        let separators = [" - ", " · ", " – "]
        for separator in separators {
            let fullPrefix = prefix + separator
            guard title.hasPrefix(fullPrefix) else { continue }
            let remainder = String(title.dropFirst(fullPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        }
        return nil
    }

    private func advanceIfNeeded() {
        guard items.count > 1 else { return }
        if pausesWhenInactive {
            guard isActive, isVisible, !isHovered, !reduceMotion, scenePhase == .active else { return }
        }
        selection = (selection + 1) % items.count
    }

    private func moveToPrevious() {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            selection = (selection - 1 + items.count) % items.count
        }
    }

    private func moveToNext() {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            selection = (selection + 1) % items.count
        }
    }

    private func clampSelection() {
        guard !items.isEmpty else {
            selection = 0
            return
        }
        if selection >= items.count {
            selection = max(items.count - 1, 0)
        }
    }
}

func mediaHomeRuntimeText(minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours > 0 {
        return String(format: NSLocalizedString("%dh %dm", comment: ""), hours, remainingMinutes)
    }
    return String(format: NSLocalizedString("%dm", comment: ""), minutes)
}
