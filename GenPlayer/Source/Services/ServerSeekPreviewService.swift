import Foundation
#if os(iOS)
import UIKit
#endif

struct MediaBrowserChapter: Sendable {
    let index: Int
    let name: String?
    let startPositionSeconds: TimeInterval
    let imageTag: String?
}

struct MediaBrowserSeekPreviewManifest: Sendable {
    let trickplay: MediaBrowserTrickplayManifest?
    let chapters: [MediaBrowserChapter]
}

struct MediaBrowserTrickplayManifest: Sendable {
    let mediaSourceId: String?
    let pathWidth: Int
    let tileWidth: Int
    let tileHeight: Int
    let thumbnailWidth: Int
    let thumbnailHeight: Int
    let thumbnailCount: Int
    let intervalMilliseconds: Int

    private var thumbnailsPerTile: Int {
        max(1, tileWidth * tileHeight)
    }

    var tileCount: Int {
        max(1, ((thumbnailCount - 1) / thumbnailsPerTile) + 1)
    }

    var preferredPathWidth: Int {
        pathWidth
    }

    func frame(at targetTime: Double) -> MediaBrowserTrickplayFrame? {
        guard tileWidth > 0,
              tileHeight > 0,
              thumbnailWidth > 0,
              thumbnailHeight > 0,
              thumbnailCount > 0 else {
            return nil
        }

        let interval = max(1, intervalMilliseconds)
        let targetMilliseconds = max(0, Int((targetTime * 1000).rounded()))
        let thumbnailIndex = min(thumbnailCount - 1, targetMilliseconds / interval)
        let tileIndex = thumbnailIndex / thumbnailsPerTile
        let indexInTile = thumbnailIndex % thumbnailsPerTile
        let row = indexInTile / tileWidth
        let column = indexInTile % tileWidth

        return MediaBrowserTrickplayFrame(
            tileIndex: tileIndex,
            row: row,
            column: column,
            thumbnailIndex: thumbnailIndex
        )
    }
}

struct MediaBrowserTrickplayFrame {
    let tileIndex: Int
    let row: Int
    let column: Int
    let thumbnailIndex: Int
}

enum MediaBrowserTrickplayManifestParser {
    static func parse(
        itemPayload: [String: Any],
        preferredMediaSourceId: String?,
        preferredThumbnailWidth: Int = 320,
        duration: TimeInterval?
    ) -> MediaBrowserSeekPreviewManifest? {
        let fallbackDuration: TimeInterval?
        if let rawTicks = intValue(forKeys: ["RunTimeTicks", "runTimeTicks"], in: itemPayload), rawTicks > 0 {
            fallbackDuration = Double(rawTicks) / 10_000_000.0
        } else {
            fallbackDuration = nil
        }
        let effectiveDuration = duration ?? fallbackDuration

        // 1. Parse Trickplay Variants
        var sourceVariants: [(mediaSourceId: String?, variants: [String: Any])] = []

        if let rawTrickplay = dictionaryValue(for: "Trickplay", in: itemPayload) {
            sourceVariants.append(contentsOf: normalizedSourceVariants(from: rawTrickplay))
        }

        if let mediaSources = itemPayload["MediaSources"] as? [[String: Any]] ?? itemPayload["mediaSources"] as? [[String: Any]] {
            for source in mediaSources {
                let sourceId = stringValue(forKeys: ["Id", "id"], in: source)
                if let sourceTrickplay = dictionaryValue(for: "Trickplay", in: source) {
                    let variants = normalizedSourceVariants(from: sourceTrickplay)
                    for variant in variants {
                        let effectiveId = variant.mediaSourceId ?? sourceId
                        if !sourceVariants.contains(where: { normalizedIdentifier($0.mediaSourceId) == normalizedIdentifier(effectiveId) && $0.variants.keys == variant.variants.keys }) {
                            sourceVariants.append((mediaSourceId: effectiveId, variants: variant.variants))
                        }
                    }
                }
            }
        }

        let normalizedPreferredSourceId = normalizedIdentifier(preferredMediaSourceId)
        let orderedVariantMaps = orderedSourceVariantMaps(
            from: sourceVariants,
            preferredMediaSourceId: normalizedPreferredSourceId
        )

        let candidateVariants = orderedVariantMaps.flatMap { variantMap in
            variantMap.variants.compactMap { widthKey, rawValue -> MediaBrowserTrickplayManifest? in
                guard let info = rawValue as? [String: Any] else { return nil }

                let pathWidth = intValue(forKeys: ["Width", "width"], in: info) ?? Int(widthKey) ?? 0
                let thumbnailWidth = intValue(forKeys: ["Width", "width"], in: info) ?? pathWidth
                let thumbnailHeight = intValue(forKeys: ["Height", "height"], in: info) ?? 0
                let tileWidth = intValue(forKeys: ["TileWidth", "tileWidth"], in: info) ?? 0
                let tileHeight = intValue(forKeys: ["TileHeight", "tileHeight"], in: info) ?? 0
                let rawThumbnailCount = intValue(forKeys: ["ThumbnailCount", "thumbnailCount"], in: info) ?? 0

                guard pathWidth > 0,
                      thumbnailWidth > 0,
                      thumbnailHeight > 0,
                      tileWidth > 0,
                      tileHeight > 0,
                      rawThumbnailCount > 0 else {
                    return nil
                }

                let intervalMilliseconds = resolvedIntervalMilliseconds(
                    rawInterval: intValue(forKeys: ["Interval", "interval"], in: info),
                    duration: effectiveDuration,
                    thumbnailCount: rawThumbnailCount
                )
                guard intervalMilliseconds > 0 else { return nil }

                let thumbnailCount = resolvedThumbnailCount(
                    rawThumbnailCount: rawThumbnailCount,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight,
                    intervalMilliseconds: intervalMilliseconds,
                    duration: effectiveDuration
                )
                guard thumbnailCount > 0 else { return nil }

                return MediaBrowserTrickplayManifest(
                    mediaSourceId: variantMap.mediaSourceId,
                    pathWidth: pathWidth,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight,
                    thumbnailWidth: thumbnailWidth,
                    thumbnailHeight: thumbnailHeight,
                    thumbnailCount: thumbnailCount,
                    intervalMilliseconds: intervalMilliseconds
                )
            }
        }

        let bestTrickplay = candidateVariants.min { lhs, rhs in
            let lhsDistance = abs(lhs.preferredPathWidth - preferredThumbnailWidth)
            let rhsDistance = abs(rhs.preferredPathWidth - preferredThumbnailWidth)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            let lhsIsPreferredSource = isPreferredSourceMatch(
                lhs.mediaSourceId,
                preferredMediaSourceId: normalizedPreferredSourceId
            )
            let rhsIsPreferredSource = isPreferredSourceMatch(
                rhs.mediaSourceId,
                preferredMediaSourceId: normalizedPreferredSourceId
            )
            if lhsIsPreferredSource != rhsIsPreferredSource {
                return lhsIsPreferredSource
            }

            if lhs.thumbnailCount != rhs.thumbnailCount {
                return lhs.thumbnailCount > rhs.thumbnailCount
            }

            if lhs.preferredPathWidth != rhs.preferredPathWidth {
                return lhs.preferredPathWidth < rhs.preferredPathWidth
            }

            let lhsSource = normalizedIdentifier(lhs.mediaSourceId) ?? ""
            let rhsSource = normalizedIdentifier(rhs.mediaSourceId) ?? ""
            return lhsSource < rhsSource
        }

        // 2. Parse Chapters (fallback for items without trickplay sprite generation, e.g. 4K items)
        var chapters: [MediaBrowserChapter] = []
        if let rawChapters = itemPayload["Chapters"] as? [[String: Any]] ?? itemPayload["chapters"] as? [[String: Any]] {
            for (index, chapterDict) in rawChapters.enumerated() {
                let ticks = intValue(forKeys: ["StartPositionTicks", "startPositionTicks"], in: chapterDict) ?? 0
                let seconds = Double(ticks) / 10_000_000.0
                let name = stringValue(forKeys: ["Name", "name"], in: chapterDict)
                let imageTag = stringValue(forKeys: ["ImageTag", "imageTag"], in: chapterDict)
                chapters.append(
                    MediaBrowserChapter(
                        index: index,
                        name: name,
                        startPositionSeconds: seconds,
                        imageTag: imageTag
                    )
                )
            }
        }

        guard bestTrickplay != nil || !chapters.isEmpty else {
            return nil
        }

        return MediaBrowserSeekPreviewManifest(
            trickplay: bestTrickplay,
            chapters: chapters
        )
    }

    private static func normalizedSourceVariants(from rawValue: Any) -> [(mediaSourceId: String?, variants: [String: Any])] {
        guard let dictionary = rawValue as? [String: Any], !dictionary.isEmpty else {
            return []
        }

        if dictionary.values.allSatisfy(looksLikeVariantInfo) {
            return [(mediaSourceId: nil, variants: dictionary)]
        }

        return dictionary.compactMap { key, value in
            guard let variants = value as? [String: Any], !variants.isEmpty else {
                return nil
            }
            return (mediaSourceId: key, variants: variants)
        }
    }

    private static func orderedSourceVariantMaps(
        from variants: [(mediaSourceId: String?, variants: [String: Any])],
        preferredMediaSourceId: String?
    ) -> [(mediaSourceId: String?, variants: [String: Any])] {
        var remaining = variants
        var ordered: [(mediaSourceId: String?, variants: [String: Any])] = []

        if let preferredMediaSourceId,
           let preferredIndex = remaining.firstIndex(where: {
               normalizedIdentifier($0.mediaSourceId) == preferredMediaSourceId
           }) {
            ordered.append(remaining.remove(at: preferredIndex))
        }

        if let sourceLessIndex = remaining.firstIndex(where: {
            normalizedIdentifier($0.mediaSourceId) == nil
        }) {
            ordered.append(remaining.remove(at: sourceLessIndex))
        }

        ordered.append(contentsOf: remaining.sorted {
            ($0.mediaSourceId ?? "") < ($1.mediaSourceId ?? "")
        })
        return ordered
    }

    private static func looksLikeVariantInfo(_ rawValue: Any) -> Bool {
        guard let dictionary = rawValue as? [String: Any] else { return false }
        return intValue(forKeys: ["ThumbnailCount", "thumbnailCount"], in: dictionary) != nil &&
            intValue(forKeys: ["TileWidth", "tileWidth"], in: dictionary) != nil
    }

    private static func isPreferredSourceMatch(
        _ mediaSourceId: String?,
        preferredMediaSourceId: String?
    ) -> Bool {
        guard let preferredMediaSourceId else { return false }
        return normalizedIdentifier(mediaSourceId) == preferredMediaSourceId
    }

    private static func resolvedThumbnailCount(
        rawThumbnailCount: Int,
        tileWidth: Int,
        tileHeight: Int,
        intervalMilliseconds: Int,
        duration: TimeInterval?
    ) -> Int {
        guard rawThumbnailCount > 0 else { return 0 }

        let thumbnailsPerTile = max(1, tileWidth * tileHeight)
        guard thumbnailsPerTile > 1,
              let estimatedThumbnailCount = estimatedThumbnailCount(
                  duration: duration,
                  intervalMilliseconds: intervalMilliseconds
              ),
              estimatedThumbnailCount > max(rawThumbnailCount, rawThumbnailCount * 4) else {
            return rawThumbnailCount
        }

        // Some Jellyfin payloads report the number of sprite sheets here instead of the
        // number of thumbnails. Expand that variant conservatively without requesting
        // tiles beyond what the current manifest can cover.
        let expandedThumbnailCount = min(
            estimatedThumbnailCount,
            rawThumbnailCount * thumbnailsPerTile
        )
        guard expandedThumbnailCount > rawThumbnailCount else {
            return rawThumbnailCount
        }

        let rawDistance = abs(estimatedThumbnailCount - rawThumbnailCount)
        let expandedDistance = abs(estimatedThumbnailCount - expandedThumbnailCount)
        return expandedDistance < rawDistance ? expandedThumbnailCount : rawThumbnailCount
    }

    private static func resolvedIntervalMilliseconds(
        rawInterval: Int?,
        duration: TimeInterval?,
        thumbnailCount: Int
    ) -> Int {
        if let rawInterval, rawInterval > 0 {
            return rawInterval
        }

        guard let duration, duration > 0, thumbnailCount > 0 else {
            return 0
        }

        return max(1, Int((duration * 1000.0) / Double(thumbnailCount)))
    }

    private static func estimatedThumbnailCount(
        duration: TimeInterval?,
        intervalMilliseconds: Int
    ) -> Int? {
        guard let duration,
              duration > 0,
              intervalMilliseconds > 0 else {
            return nil
        }

        let durationMilliseconds = max(1, Int((duration * 1000.0).rounded(.down)))
        return max(1, durationMilliseconds / intervalMilliseconds)
    }

    private static func dictionaryValue(for key: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { candidate, _ in
            candidate.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    private static func intValue(forKeys keys: [String], in dictionary: [String: Any]) -> Int? {
        for key in keys {
            guard let rawValue = dictionaryValue(for: key, in: dictionary) else { continue }
            if let intValue = rawValue as? Int {
                return intValue
            }
            if let number = rawValue as? NSNumber {
                return number.intValue
            }
            if let doubleValue = rawValue as? Double {
                return Int(doubleValue)
            }
            if let stringValue = rawValue as? String,
               let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }

        return nil
    }

    private static func stringValue(forKeys keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let rawValue = dictionaryValue(for: key, in: dictionary) else { continue }
            if let stringValue = rawValue as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func normalizedIdentifier(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

final class ServerSeekPreviewService {
    static let shared = ServerSeekPreviewService()
    private let aggressiveTrickplayPrefetchTileLimit = 12

    private let finalImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 180
        return cache
    }()

    private let tileImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private let trickplayManifestCache = TrickplayManifestCache()
    private let trickplayTileRequestCache = TrickplayTileRequestCache()
    private let directPreviewAvailabilityCache = DirectPreviewAvailabilityCache()

    private init() {}

    func previewImage(for item: MediaItem, targetTime: Double) async -> UIImage? {
        guard let context = resolvedContext(for: item) else { return nil }

        let resolvedImage: UIImage?
        switch context.server.type {
        case .jellyfin:
            resolvedImage = await mediaBrowserPreviewImage(
                context: context,
                fetchManifest: { context in
                    await JellyfinService.shared.fetchSeekPreviewManifest(
                        server: context.server,
                        itemId: context.itemId,
                        userId: context.userId,
                        token: context.token,
                        mediaSourceId: context.mediaSourceId,
                        duration: context.duration
                    )
                },
                fetchTileImage: { context, width, tileIndex in
                    await JellyfinService.shared.fetchSeekPreviewTileImage(
                        server: context.server,
                        itemId: context.itemId,
                        token: context.token,
                        mediaSourceId: context.mediaSourceId,
                        width: width,
                        tileIndex: tileIndex
                    )
                },
                fetchChapterImage: { context, chapterIndex, imageTag in
                    await JellyfinService.shared.fetchSeekPreviewChapterImage(
                        server: context.server,
                        itemId: context.itemId,
                        token: context.token,
                        chapterIndex: chapterIndex,
                        imageTag: imageTag
                    )
                },
                targetTime: targetTime
            )
        case .emby:
            resolvedImage = await mediaBrowserPreviewImage(
                context: context,
                fetchManifest: { context in
                    await EmbyService.shared.fetchSeekPreviewManifest(
                        server: context.server,
                        itemId: context.itemId,
                        userId: context.userId,
                        token: context.token,
                        mediaSourceId: context.mediaSourceId,
                        duration: context.duration
                    )
                },
                fetchTileImage: { context, width, tileIndex in
                    await EmbyService.shared.fetchSeekPreviewTileImage(
                        server: context.server,
                        itemId: context.itemId,
                        token: context.token,
                        mediaSourceId: context.mediaSourceId,
                        width: width,
                        tileIndex: tileIndex
                    )
                },
                fetchChapterImage: { context, chapterIndex, imageTag in
                    await EmbyService.shared.fetchSeekPreviewChapterImage(
                        server: context.server,
                        itemId: context.itemId,
                        token: context.token,
                        chapterIndex: chapterIndex,
                        imageTag: imageTag
                    )
                },
                targetTime: targetTime
            )
        case .plex:
            let cacheKey = previewCacheKey(for: context, targetTime: targetTime) as NSString
            if let cachedImage = finalImageCache.object(forKey: cacheKey) {
                return cachedImage
            }
            resolvedImage = await plexPreviewImage(context: context, targetTime: targetTime)
            if let resolvedImage {
                finalImageCache.setObject(resolvedImage, forKey: cacheKey)
            }
        default:
            resolvedImage = nil
        }

        return resolvedImage
    }

    func trickplayFrameIntervalSeconds(for item: MediaItem) async -> Double? {
        guard let context = resolvedContext(for: item) else { return nil }

        let manifest: MediaBrowserSeekPreviewManifest?
        switch context.server.type {
        case .jellyfin:
            manifest = await mediaBrowserManifest(
                context: context,
                fetchManifest: { context in
                    await JellyfinService.shared.fetchSeekPreviewManifest(
                        server: context.server,
                        itemId: context.itemId,
                        userId: context.userId,
                        token: context.token,
                        mediaSourceId: context.mediaSourceId,
                        duration: context.duration
                    )
                }
            )
        case .emby:
            manifest = await mediaBrowserManifest(
                context: context,
                fetchManifest: { context in
                    await EmbyService.shared.fetchSeekPreviewManifest(
                        server: context.server,
                        itemId: context.itemId,
                        userId: context.userId,
                        token: context.token,
                        mediaSourceId: context.mediaSourceId,
                        duration: context.duration
                    )
                }
            )
        default:
            manifest = nil
        }

        guard let trickplay = manifest?.trickplay else { return nil }
        return Double(trickplay.intervalMilliseconds) / 1000.0
    }

    private func mediaBrowserPreviewImage(
        context: SeekPreviewContext,
        fetchManifest: @escaping (SeekPreviewContext) async -> MediaBrowserSeekPreviewManifest?,
        fetchTileImage: @escaping (SeekPreviewContext, Int, Int) async -> UIImage?,
        fetchChapterImage: @escaping (SeekPreviewContext, Int, String?) async -> UIImage?,
        targetTime: Double
    ) async -> UIImage? {
        guard let manifest = await mediaBrowserManifest(
            context: context,
            fetchManifest: fetchManifest
        ) else {
            return nil
        }

        // 1. Try high-precision trickplay sprite sheet first
        if let trickplay = manifest.trickplay, let frame = trickplay.frame(at: targetTime) {
            let resolvedMediaSourceId = trickplay.mediaSourceId ?? context.mediaSourceId
            let tileContext = context.withMediaSourceId(resolvedMediaSourceId)

            let frameCacheKey = trickplayFrameCacheKey(
                for: tileContext,
                width: trickplay.preferredPathWidth,
                frame: frame
            ) as NSString
            if let cachedImage = finalImageCache.object(forKey: frameCacheKey) {
                return cachedImage
            }

            let tileImage = await trickplayTileImage(
                context: tileContext,
                width: trickplay.preferredPathWidth,
                tileIndex: frame.tileIndex,
                fetchTileImage: fetchTileImage
            )

            if let tileImage {
                prefetchAdjacentTrickplayTiles(
                    around: frame.tileIndex,
                    manifest: trickplay,
                    context: tileContext,
                    fetchTileImage: fetchTileImage
                )
                let croppedImage = crop(tileImage: tileImage, manifest: trickplay, frame: frame)
                if let croppedImage {
                    finalImageCache.setObject(croppedImage, forKey: frameCacheKey)
                    return croppedImage
                }
            }
        }

        // 2. Fall back to chapter preview image (e.g. 4K items without trickplay sprite generation)
        if !manifest.chapters.isEmpty {
            if let chapter = matchingChapter(for: targetTime, in: manifest.chapters) {
                let cacheKey = "server-seek-chapter|\(context.server.id.uuidString)|\(context.itemId)|\(chapter.index)" as NSString
                if let cachedImage = finalImageCache.object(forKey: cacheKey) {
                    return cachedImage
                }

                if let chapterImage = await fetchChapterImage(context, chapter.index, chapter.imageTag) {
                    finalImageCache.setObject(chapterImage, forKey: cacheKey)
                    return chapterImage
                }
            }
        }

        return nil
    }

    private func matchingChapter(
        for targetTime: Double,
        in chapters: [MediaBrowserChapter]
    ) -> MediaBrowserChapter? {
        let validChapters = chapters.sorted { $0.startPositionSeconds < $1.startPositionSeconds }
        guard let first = validChapters.first, targetTime >= first.startPositionSeconds else {
            return validChapters.first
        }
        return validChapters.last { $0.startPositionSeconds <= targetTime }
    }

    private func mediaBrowserManifest(
        context: SeekPreviewContext,
        fetchManifest: @escaping (SeekPreviewContext) async -> MediaBrowserSeekPreviewManifest?
    ) async -> MediaBrowserSeekPreviewManifest? {
        let manifestKey = trickplayManifestKey(for: context)
        return await trickplayManifestCache.manifest(forKey: manifestKey) {
            await fetchManifest(context)
        }
    }

    private func plexPreviewImage(
        context: SeekPreviewContext,
        targetTime: Double
    ) async -> UIImage? {
        guard let partId = context.plexPartId else { return nil }
        let availabilityKey = plexPreviewAvailabilityKey(for: context, partId: partId)
        if await directPreviewAvailabilityCache.isKnownMissing(forKey: availabilityKey) {
            return nil
        }

        let offsetMilliseconds = max(0, Int64((targetTime * 1000.0).rounded()))
        let image = await PlexService.shared.fetchSeekPreviewImage(
            server: context.server,
            partId: partId,
            offsetMilliseconds: offsetMilliseconds
        )
        if image == nil {
            await directPreviewAvailabilityCache.markMissing(forKey: availabilityKey)
        } else {
            await directPreviewAvailabilityCache.markAvailable(forKey: availabilityKey)
        }
        return image
    }

    private func trickplayTileImage(
        context: SeekPreviewContext,
        width: Int,
        tileIndex: Int,
        fetchTileImage: @escaping (SeekPreviewContext, Int, Int) async -> UIImage?
    ) async -> UIImage? {
        let tileCacheKey = trickplayTileCacheKey(
            for: context,
            width: width,
            tileIndex: tileIndex
        )
        let nsTileCacheKey = tileCacheKey as NSString

        if let cachedTileImage = tileImageCache.object(forKey: nsTileCacheKey) {
            return cachedTileImage
        }

        let resolvedTileImage = await trickplayTileRequestCache.image(forKey: tileCacheKey) {
            await fetchTileImage(context, width, tileIndex)
        }

        if let resolvedTileImage {
            tileImageCache.setObject(resolvedTileImage, forKey: nsTileCacheKey)
        }

        return resolvedTileImage
    }

    private func prefetchAdjacentTrickplayTiles(
        around tileIndex: Int,
        manifest: MediaBrowserTrickplayManifest,
        context: SeekPreviewContext,
        fetchTileImage: @escaping (SeekPreviewContext, Int, Int) async -> UIImage?
    ) {
        let candidateTileIndices: [Int]
        if manifest.tileCount <= aggressiveTrickplayPrefetchTileLimit {
            candidateTileIndices = (0..<manifest.tileCount)
                .filter { $0 != tileIndex }
                .sorted { abs($0 - tileIndex) < abs($1 - tileIndex) }
        } else {
            candidateTileIndices = [tileIndex + 1, tileIndex - 1].filter {
                $0 >= 0 && $0 < manifest.tileCount
            }
        }

        for adjacentTileIndex in candidateTileIndices {
            let tileCacheKey = trickplayTileCacheKey(
                for: context,
                width: manifest.preferredPathWidth,
                tileIndex: adjacentTileIndex
            )
            if tileImageCache.object(forKey: tileCacheKey as NSString) != nil {
                continue
            }

            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = await self.trickplayTileImage(
                    context: context,
                    width: manifest.preferredPathWidth,
                    tileIndex: adjacentTileIndex,
                    fetchTileImage: fetchTileImage
                )
            }
        }
    }

    private func crop(
        tileImage: UIImage,
        manifest: MediaBrowserTrickplayManifest,
        frame: MediaBrowserTrickplayFrame
    ) -> UIImage? {
        guard let cgImage = tileImage.cgImage else { return tileImage }

        let scaleX = CGFloat(cgImage.width) / max(tileImage.size.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(tileImage.size.height, 1)
        let cropRect = CGRect(
            x: CGFloat(frame.column * manifest.thumbnailWidth) * scaleX,
            y: CGFloat(frame.row * manifest.thumbnailHeight) * scaleY,
            width: CGFloat(manifest.thumbnailWidth) * scaleX,
            height: CGFloat(manifest.thumbnailHeight) * scaleY
        ).integral

        guard cropRect.width > 0,
              cropRect.height > 0,
              cropRect.maxX <= CGFloat(cgImage.width),
              cropRect.maxY <= CGFloat(cgImage.height),
              let cropped = cgImage.cropping(to: cropRect) else {
            return tileImage
        }

        return UIImage(cgImage: cropped, scale: tileImage.scale, orientation: tileImage.imageOrientation)
    }

    private func resolvedContext(for item: MediaItem) -> SeekPreviewContext? {
        guard item.isRemote,
              let itemId = normalizedIdentifier(item.jellyfinItemId),
              let server = resolvedServer(for: item) else {
            return nil
        }

        let mediaSourceId = normalizedIdentifier(
            item.mediaSourceId ?? queryValue(named: "MediaSourceId", in: item.url)
        )
        let token: String?
        switch server.type {
        case .jellyfin, .emby:
            token = normalizedIdentifier(
                queryValue(named: "api_key", in: item.url) ??
                queryValue(named: "X-Emby-Token", in: item.url) ??
                server.accessToken
            )
        case .plex:
            token = normalizedIdentifier(
                queryValue(named: "X-Plex-Token", in: item.url) ??
                server.accessToken ??
                server.passwordSecret
            )
        default:
            token = nil
        }

        guard let token, !token.isEmpty else {
            return nil
        }

        return SeekPreviewContext(
            server: server,
            itemId: itemId,
            token: token,
            userId: normalizedIdentifier(server.userId),
            mediaSourceId: mediaSourceId,
            duration: item.videoFile?.duration,
            plexPartId: resolvedPlexPartId(for: item)
        )
    }

    private func resolvedServer(for item: MediaItem) -> ServerConfig? {
        if let resolvedServer = item.videoFile?.resolvedServer {
            return AppNetworkService.shared.hydratedServer(from: resolvedServer)
        }

        if let serverId = normalizedIdentifier(item.jellyfinServerId),
           let server = AppNetworkService.shared.servers.first(where: {
               $0.id.uuidString.lowercased() == serverId.lowercased()
           }) {
            return AppNetworkService.shared.hydratedServer(from: server)
        }

        return nil
    }

    private func resolvedPlexPartId(for item: MediaItem) -> String? {
        [item.url, item.videoFile?.url].compactMap { $0 }.lazy.compactMap { url in
            let components = url.pathComponents
            guard let partIndex = components.firstIndex(of: "parts"),
                  partIndex + 1 < components.count else {
                return nil
            }
            return self.normalizedIdentifier(components[partIndex + 1])
        }.first
    }

    private func queryValue(named name: String, in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        })?.value
    }

    private func normalizedIdentifier(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func previewCacheKey(for context: SeekPreviewContext, targetTime: Double) -> String {
        let roundedTimeBucket = Int((max(targetTime, 0) * 2.0).rounded())
        return "server-seek-preview|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")|\(roundedTimeBucket)"
    }

    private func trickplayManifestKey(for context: SeekPreviewContext) -> String {
        "server-seek-manifest|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")"
    }

    private func trickplayTileCacheKey(for context: SeekPreviewContext, width: Int, tileIndex: Int) -> String {
        "server-seek-tile|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")|\(width)|\(tileIndex)"
    }

    private func trickplayFrameCacheKey(
        for context: SeekPreviewContext,
        width: Int,
        frame: MediaBrowserTrickplayFrame
    ) -> String {
        "server-seek-frame|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")|\(width)|\(frame.thumbnailIndex)"
    }

    private func plexPreviewAvailabilityKey(for context: SeekPreviewContext, partId: String) -> String {
        "server-seek-plex-availability|\(context.server.id.uuidString)|\(partId)"
    }
}

private struct SeekPreviewContext {
    let server: ServerConfig
    let itemId: String
    let token: String
    let userId: String?
    let mediaSourceId: String?
    let duration: TimeInterval?
    let plexPartId: String?

    func withMediaSourceId(_ mediaSourceId: String?) -> SeekPreviewContext {
        SeekPreviewContext(
            server: server,
            itemId: itemId,
            token: token,
            userId: userId,
            mediaSourceId: mediaSourceId,
            duration: duration,
            plexPartId: plexPartId
        )
    }
}

private actor TrickplayManifestCache {
    private var manifests: [String: MediaBrowserSeekPreviewManifest] = [:]
    private var missingManifestTimestamps: [String: Date] = [:]
    private var inFlightTasks: [String: Task<MediaBrowserSeekPreviewManifest?, Never>] = [:]
    // Keep the negative-cache window short so one slow timeout does not suppress
    // trickplay for the rest of the current scrubbing session.
    private let missingManifestRetryInterval: TimeInterval = 3

    func manifest(
        forKey key: String,
        loader: @escaping () async -> MediaBrowserSeekPreviewManifest?
    ) async -> MediaBrowserSeekPreviewManifest? {
        if let manifest = manifests[key] {
            return manifest
        }

        if let markedAt = missingManifestTimestamps[key] {
            if Date().timeIntervalSince(markedAt) < missingManifestRetryInterval {
                return nil
            }
            missingManifestTimestamps.removeValue(forKey: key)
        }

        if let inFlightTask = inFlightTasks[key] {
            return await inFlightTask.value
        }

        let task = Task<MediaBrowserSeekPreviewManifest?, Never> {
            await loader()
        }
        inFlightTasks[key] = task

        let resolvedManifest = await task.value
        inFlightTasks.removeValue(forKey: key)

        if let resolvedManifest {
            manifests[key] = resolvedManifest
            missingManifestTimestamps.removeValue(forKey: key)
        } else {
            manifests.removeValue(forKey: key)
            missingManifestTimestamps[key] = Date()
        }
        return resolvedManifest
    }
}

private actor TrickplayTileRequestCache {
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    func image(
        forKey key: String,
        loader: @escaping () async -> UIImage?
    ) async -> UIImage? {
        if let inFlightTask = inFlightTasks[key] {
            return await inFlightTask.value
        }

        let task = Task<UIImage?, Never> {
            await loader()
        }
        inFlightTasks[key] = task

        let resolvedImage = await task.value
        inFlightTasks.removeValue(forKey: key)
        return resolvedImage
    }
}

private actor DirectPreviewAvailabilityCache {
    private var missingTimestamps: [String: Date] = [:]
    private let retryInterval: TimeInterval = 45

    func isKnownMissing(forKey key: String) -> Bool {
        guard let markedAt = missingTimestamps[key] else {
            return false
        }

        if Date().timeIntervalSince(markedAt) < retryInterval {
            return true
        }

        missingTimestamps.removeValue(forKey: key)
        return false
    }

    func markMissing(forKey key: String) {
        missingTimestamps[key] = Date()
    }

    func markAvailable(forKey key: String) {
        missingTimestamps.removeValue(forKey: key)
    }
}
