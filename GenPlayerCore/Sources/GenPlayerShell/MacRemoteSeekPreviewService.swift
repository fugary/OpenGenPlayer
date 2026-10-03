#if os(macOS)
import AppKit
import Foundation
import AVFoundation
import GenPlayerCore

final class MacRemoteSeekPreviewService {
    static let shared = MacRemoteSeekPreviewService()

    private let session: URLSession
    private let finalImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        return cache
    }()
    private let tileImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()
    private let manifestCache = MacRemoteTrickplayManifestCache()

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    func clearCache() {
        finalImageCache.removeAllObjects()
        tileImageCache.removeAllObjects()
        Task {
            await manifestCache.clear()
        }
    }

    func canPreview(_ file: VideoFile) -> Bool {
        guard file.isRemote,
              tvTrimmedPlaybackText(file.jellyfinItemId) != nil,
              let server = tvPlaybackResolvedServer(for: file) else {
            return false
        }
        switch server.type {
        case .jellyfin, .emby, .plex:
            return previewToken(for: file, server: server) != nil
        default:
            return false
        }
    }

    func previewImage(for file: VideoFile, targetTime: TimeInterval, duration: TimeInterval) async -> NSImage? {
        let targetTimeSeconds = targetTime / 1000.0
        let durationSeconds = duration / 1000.0
        // 1. Try server-side trickplay first for media server files
        if let context = await resolvedContext(for: file, duration: durationSeconds) {
            switch context.server.type {
            case .jellyfin, .emby:
                if let img = await mediaBrowserPreviewImage(context: context, targetTime: targetTimeSeconds) {
                    return img
                }
            case .plex:
                if let img = await plexPreviewImage(context: context, targetTime: targetTimeSeconds) {
                    return img
                }
            default:
                break
            }
        }
        
        // 2. Fall back to AVAssetImageGenerator for local files (avoids VLC thread contention and deadlocks)
        return await localPreviewImage(for: file, targetTime: targetTime, duration: duration)
    }

    private func localPreviewImage(for file: VideoFile, targetTime: TimeInterval, duration: TimeInterval) async -> NSImage? {
        guard duration > 500 else { return nil }
        
        let targetTimeSeconds = targetTime / 1000.0
        let cacheKey = "local_\(file.url.absoluteString)_\(Int(targetTimeSeconds))" as NSString
        if let cached = finalImageCache.object(forKey: cacheKey) {
            return cached
        }

        guard file.url.isFileURL else {
            return nil
        }

        let asset = AVURLAsset(url: file.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 202)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)

        let cmTime = CMTime(seconds: max(0, targetTimeSeconds), preferredTimescale: 600)
        let image: NSImage? = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime)]) { _, cgImage, _, result, _ in
                if let cgImage = cgImage, result == .succeeded {
                    let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    continuation.resume(returning: img)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }

        if let image {
            finalImageCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    private func mediaBrowserPreviewImage(
        context: MacRemoteSeekPreviewContext,
        targetTime: TimeInterval
    ) async -> NSImage? {
        guard let manifest = await mediaBrowserManifest(context: context) else {
            return nil
        }

        // 1. Try high-precision trickplay sprite sheet first
        if let trickplay = manifest.trickplay, let frame = trickplay.frame(at: targetTime) {
            let tileContext = context.withMediaSourceId(trickplay.mediaSourceId ?? context.mediaSourceId)
            let frameCacheKey = trickplayFrameCacheKey(
                for: tileContext,
                width: trickplay.pathWidth,
                frame: frame
            ) as NSString
            if let cachedImage = finalImageCache.object(forKey: frameCacheKey) {
                return cachedImage
            }

            if let tileImage = await trickplayTileImage(
                context: tileContext,
                width: trickplay.pathWidth,
                tileIndex: frame.tileIndex
            ) {
                prefetchAdjacentTrickplayTiles(around: frame.tileIndex, manifest: trickplay, context: tileContext)
                let croppedImage = crop(tileImage: tileImage, manifest: trickplay, frame: frame)
                if let croppedImage {
                    finalImageCache.setObject(croppedImage, forKey: frameCacheKey)
                    return croppedImage
                }
            }
        }

        // 2. Fall back to chapter preview image (for 4K resources or media without trickplay sprite generation)
        if !manifest.chapters.isEmpty {
            if let chapter = matchingChapter(for: targetTime, in: manifest.chapters) {
                if let chapterImage = await chapterPreviewImage(context: context, chapter: chapter) {
                    return chapterImage
                }
            }
        }

        return nil
    }

    private func matchingChapter(
        for targetTime: TimeInterval,
        in chapters: [MediaBrowserChapter]
    ) -> MediaBrowserChapter? {
        let validChapters = chapters.sorted { $0.startPositionSeconds < $1.startPositionSeconds }
        guard let first = validChapters.first, targetTime >= first.startPositionSeconds else {
            return validChapters.first
        }
        return validChapters.last { $0.startPositionSeconds <= targetTime }
    }

    private func chapterPreviewImage(
        context: MacRemoteSeekPreviewContext,
        chapter: MediaBrowserChapter
    ) async -> NSImage? {
        let cacheKey = "chapter|\(context.server.id.uuidString)|\(context.itemId)|\(chapter.index)" as NSString
        if let cachedImage = finalImageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let url = mediaBrowserChapterImageURL(context: context, chapterIndex: chapter.index, imageTag: chapter.imageTag) else {
            return nil
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
            applyMediaBrowserHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                return nil
            }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            finalImageCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    private func mediaBrowserChapterImageURL(
        context: MacRemoteSeekPreviewContext,
        chapterIndex: Int,
        imageTag: String?
    ) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(
            string: "\(baseURL)/Items/\(context.itemId)/Images/Chapter/\(chapterIndex)"
        ) else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "api_key", value: context.token),
            URLQueryItem(name: "maxWidth", value: "480")
        ]
        if let tag = tvTrimmedPlaybackText(imageTag) {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func mediaBrowserManifest(context: MacRemoteSeekPreviewContext) async -> MacMediaBrowserSeekPreviewManifest? {
        let manifestKey = trickplayManifestKey(for: context)
        return await manifestCache.manifest(forKey: manifestKey) {
            await self.fetchMediaBrowserManifest(context: context)
        }
    }

    private func fetchMediaBrowserManifest(context: MacRemoteSeekPreviewContext) async -> MacMediaBrowserSeekPreviewManifest? {
        guard let url = mediaBrowserItemDetailsURL(context: context) else {
            return nil
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            applyMediaBrowserHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return MacMediaBrowserTrickplayManifestParser.parse(
                itemPayload: payload,
                preferredMediaSourceId: context.mediaSourceId,
                duration: context.duration
            )
        } catch {
            return nil
        }
    }

    private func trickplayTileImage(
        context: MacRemoteSeekPreviewContext,
        width: Int,
        tileIndex: Int
    ) async -> NSImage? {
        let cacheKey = trickplayTileCacheKey(for: context, width: width, tileIndex: tileIndex)
        if let cachedImage = tileImageCache.object(forKey: cacheKey as NSString) {
            return cachedImage
        }

        guard let url = mediaBrowserTrickplayTileURL(context: context, width: width, tileIndex: tileIndex) else {
            return nil
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
            applyMediaBrowserHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                return nil
            }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            tileImageCache.setObject(image, forKey: cacheKey as NSString)
            return image
        } catch {
            return nil
        }
    }

    private func prefetchAdjacentTrickplayTiles(
        around tileIndex: Int,
        manifest: MacMediaBrowserTrickplayManifest,
        context: MacRemoteSeekPreviewContext
    ) {
        let candidateTileIndices: [Int]
        if manifest.tileCount <= 12 {
            candidateTileIndices = (0..<manifest.tileCount)
                .filter { $0 != tileIndex }
                .sorted { abs($0 - tileIndex) < abs($1 - tileIndex) }
        } else {
            candidateTileIndices = [tileIndex + 1, tileIndex - 1].filter {
                $0 >= 0 && $0 < manifest.tileCount
            }
        }

        for adjacentTileIndex in candidateTileIndices {
            let cacheKey = trickplayTileCacheKey(
                for: context,
                width: manifest.pathWidth,
                tileIndex: adjacentTileIndex
            )
            if tileImageCache.object(forKey: cacheKey as NSString) != nil {
                continue
            }

            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = await self.trickplayTileImage(
                    context: context,
                    width: manifest.pathWidth,
                    tileIndex: adjacentTileIndex
                )
            }
        }
    }

    private func plexPreviewImage(
        context: MacRemoteSeekPreviewContext,
        targetTime: TimeInterval
    ) async -> NSImage? {
        guard let partId = context.plexPartId,
              let url = plexPreviewURL(context: context, partId: partId, targetTime: targetTime) else {
            return nil
        }

        let cacheKey = plexPreviewCacheKey(for: context, partId: partId, targetTime: targetTime) as NSString
        if let cachedImage = finalImageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 1.8
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
            applyPlexHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = NSImage(data: data) else {
                return nil
            }

            finalImageCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    private func crop(
        tileImage: NSImage,
        manifest: MacMediaBrowserTrickplayManifest,
        frame: MacMediaBrowserTrickplayFrame
    ) -> NSImage? {
        guard let cgImage = tileImage.cgImage else { return tileImage }

        let tilePixelWidth = CGFloat(cgImage.width)
        let tilePixelHeight = CGFloat(cgImage.height)
        let expectedTotalWidth = CGFloat(manifest.tileWidth * manifest.thumbnailWidth)
        let expectedTotalHeight = CGFloat(manifest.tileHeight * manifest.thumbnailHeight)
        
        let scaleX = expectedTotalWidth > 0 ? (tilePixelWidth / expectedTotalWidth) : 1.0
        let scaleY = expectedTotalHeight > 0 ? (tilePixelHeight / expectedTotalHeight) : 1.0

        let cropX = CGFloat(frame.column * manifest.thumbnailWidth) * scaleX
        let cropY = CGFloat(frame.row * manifest.thumbnailHeight) * scaleY
        let cropW = CGFloat(manifest.thumbnailWidth) * scaleX
        let cropH = CGFloat(manifest.thumbnailHeight) * scaleY
        
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH).integral
        let imageBounds = CGRect(x: 0, y: 0, width: tilePixelWidth, height: tilePixelHeight)
        let safeCropRect = cropRect.intersection(imageBounds)

        guard !safeCropRect.isEmpty,
              safeCropRect.width > 0,
              safeCropRect.height > 0,
              let cropped = cgImage.cropping(to: safeCropRect) else {
            return tileImage
        }

        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    private func resolvedContext(for file: VideoFile, duration: TimeInterval?) async -> MacRemoteSeekPreviewContext? {
        guard file.isRemote,
              let itemId = tvTrimmedPlaybackText(file.jellyfinItemId),
              let server = tvPlaybackResolvedServer(for: file),
              let token = previewToken(for: file, server: server) else {
            return nil
        }

        let mediaSourceId = tvTrimmedPlaybackText(
            URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame })?.value
        )
        let userId: String?
        if server.type == .jellyfin || server.type == .emby {
            if let storedUserId = tvTrimmedPlaybackText(server.userId) {
                userId = storedUserId
            } else {
                userId = tvTrimmedPlaybackText(server.userId)
            }
        } else {
            userId = nil
        }

        return MacRemoteSeekPreviewContext(
            server: server,
            itemId: itemId,
            token: token,
            userId: userId,
            mediaSourceId: mediaSourceId,
            duration: file.duration ?? duration,
            plexPartId: plexPartId(for: file)
        )
    }

    private func previewToken(for file: VideoFile, server: ServerConfig) -> String? {
        switch server.type {
        case .jellyfin, .emby:
            return tvTrimmedPlaybackText(URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })?.value)
                ?? tvTrimmedPlaybackText(URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("X-Emby-Token") == .orderedSame })?.value)
                ?? tvTrimmedPlaybackText(server.accessToken)
                ?? tvTrimmedPlaybackText(server.passwordSecret)
        case .plex:
            return tvTrimmedPlaybackText(URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame })?.value)
                ?? tvTrimmedPlaybackText(server.accessToken)
                ?? tvTrimmedPlaybackText(server.passwordSecret)
        default:
            return nil
        }
    }

    private func mediaBrowserItemDetailsURL(context: MacRemoteSeekPreviewContext) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path: String
        if let userId = tvTrimmedPlaybackText(context.userId) {
            path = "/Users/\(userId)/Items/\(context.itemId)"
        } else {
            path = "/Items/\(context.itemId)"
        }

        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "Fields", value: "Trickplay,MediaSources,Chapters"),
            URLQueryItem(name: "api_key", value: context.token)
        ]
        return components.url
    }

    private func mediaBrowserTrickplayTileURL(
        context: MacRemoteSeekPreviewContext,
        width: Int,
        tileIndex: Int
    ) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(
            string: "\(baseURL)/Videos/\(context.itemId)/Trickplay/\(width)/\(tileIndex).jpg"
        ) else {
            return nil
        }

        var queryItems = [URLQueryItem(name: "api_key", value: context.token)]
        if let mediaSourceId = tvTrimmedPlaybackText(context.mediaSourceId) {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func plexPreviewURL(
        context: MacRemoteSeekPreviewContext,
        partId: String,
        targetTime: TimeInterval
    ) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let offsetMilliseconds = max(0, Int64((targetTime * 1000.0).rounded()))
        guard var components = URLComponents(
            string: "\(baseURL)/library/parts/\(partId)/indexes/sd/\(offsetMilliseconds)"
        ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: context.token)]
        return components.url
    }

    private func applyMediaBrowserHeaders(
        to request: inout URLRequest,
        context: MacRemoteSeekPreviewContext
    ) {
        request.setValue("application/json,image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue(context.token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(context.token, forHTTPHeaderField: "X-MediaBrowser-Token")
        request.setValue(
            "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\", Token=\"\(context.token)\"",
            forHTTPHeaderField: "Authorization"
        )
    }

    private func applyPlexHeaders(
        to request: inout URLRequest,
        context: MacRemoteSeekPreviewContext
    ) {
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-tvOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue("GenPlayerTV", forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(context.token, forHTTPHeaderField: "X-Plex-Token")
    }

    private func plexPartId(for file: VideoFile) -> String? {
        let components = file.url.pathComponents
        guard let partIndex = components.firstIndex(of: "parts"),
              partIndex + 1 < components.count else {
            return nil
        }
        return tvTrimmedPlaybackText(components[partIndex + 1])
    }

    private func trickplayManifestKey(for context: MacRemoteSeekPreviewContext) -> String {
        "tv-remote-seek-manifest|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")"
    }

    private func trickplayTileCacheKey(
        for context: MacRemoteSeekPreviewContext,
        width: Int,
        tileIndex: Int
    ) -> String {
        "tv-remote-seek-tile|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")|\(width)|\(tileIndex)"
    }

    private func trickplayFrameCacheKey(
        for context: MacRemoteSeekPreviewContext,
        width: Int,
        frame: MacMediaBrowserTrickplayFrame
    ) -> String {
        "tv-remote-seek-frame|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")|\(width)|\(frame.thumbnailIndex)"
    }

    private func plexPreviewCacheKey(
        for context: MacRemoteSeekPreviewContext,
        partId: String,
        targetTime: TimeInterval
    ) -> String {
        let roundedTimeBucket = Int((max(targetTime, 0) * 2.0).rounded())
        return "tv-remote-seek-plex|\(context.server.id.uuidString)|\(partId)|\(roundedTimeBucket)"
    }
}

private struct MacRemoteSeekPreviewContext {
    let server: ServerConfig
    let itemId: String
    let token: String
    let userId: String?
    let mediaSourceId: String?
    let duration: TimeInterval?
    let plexPartId: String?

    func withMediaSourceId(_ mediaSourceId: String?) -> MacRemoteSeekPreviewContext {
        MacRemoteSeekPreviewContext(
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


struct MediaBrowserChapter: Sendable {
    let index: Int
    let name: String?
    let startPositionSeconds: TimeInterval
    let imageTag: String?
}

struct MacMediaBrowserSeekPreviewManifest: Sendable {
    let trickplay: MacMediaBrowserTrickplayManifest?
    let chapters: [MediaBrowserChapter]
}

struct MacMediaBrowserTrickplayManifest: Sendable {
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

    func frame(at targetTime: TimeInterval) -> MacMediaBrowserTrickplayFrame? {
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
        return MacMediaBrowserTrickplayFrame(
            tileIndex: tileIndex,
            row: indexInTile / tileWidth,
            column: indexInTile % tileWidth,
            thumbnailIndex: thumbnailIndex
        )
    }
}

struct MacMediaBrowserTrickplayFrame {
    let tileIndex: Int
    let row: Int
    let column: Int
    let thumbnailIndex: Int
}

enum MacMediaBrowserTrickplayManifestParser {
    static func parse(
        itemPayload: [String: Any],
        preferredMediaSourceId: String?,
        preferredThumbnailWidth: Int = 320,
        duration: TimeInterval?
    ) -> MacMediaBrowserSeekPreviewManifest? {
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
            variantMap.variants.compactMap { widthKey, rawValue -> MacMediaBrowserTrickplayManifest? in
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

                return MacMediaBrowserTrickplayManifest(
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
            let lhsDistance = abs(lhs.pathWidth - preferredThumbnailWidth)
            let rhsDistance = abs(rhs.pathWidth - preferredThumbnailWidth)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            let lhsIsPreferredSource = normalizedIdentifier(lhs.mediaSourceId) == normalizedPreferredSourceId
            let rhsIsPreferredSource = normalizedIdentifier(rhs.mediaSourceId) == normalizedPreferredSourceId
            if lhsIsPreferredSource != rhsIsPreferredSource {
                return lhsIsPreferredSource
            }

            if lhs.thumbnailCount != rhs.thumbnailCount {
                return lhs.thumbnailCount > rhs.thumbnailCount
            }

            return lhs.pathWidth < rhs.pathWidth
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

        return MacMediaBrowserSeekPreviewManifest(
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
actor MacRemoteTrickplayManifestCache {
    private var manifests: [String: MacMediaBrowserSeekPreviewManifest] = [:]
    private var missingManifestTimestamps: [String: Date] = [:]
    private var inFlightTasks: [String: Task<MacMediaBrowserSeekPreviewManifest?, Never>] = [:]
    private let missingManifestRetryInterval: TimeInterval = 3

    func manifest(
        forKey key: String,
        loader: @escaping () async -> MacMediaBrowserSeekPreviewManifest?
    ) async -> MacMediaBrowserSeekPreviewManifest? {
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

        let task = Task<MacMediaBrowserSeekPreviewManifest?, Never> {
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

    func clear() {
        manifests.removeAll()
        missingManifestTimestamps.removeAll()
        inFlightTasks.removeAll()
    }
}

private func tvTrimmedPlaybackText(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        return nil
    }
    return text
}

private func tvPlaybackResolvedServer(for file: VideoFile) -> ServerConfig? {
    let servers = AppNetworkService.shared.servers
    if let serverId = tvTrimmedPlaybackText(file.jellyfinServerId),
       let uuid = UUID(uuidString: serverId),
       let match = servers.first(where: { $0.id == uuid }) {
        return AppNetworkService.shared.hydratedServer(from: match)
    }
    if let match = servers.first(where: { $0.type == file.serverType }) {
        return AppNetworkService.shared.hydratedServer(from: match)
    }
    return nil
}


extension NSImage {
    var cgImage: CGImage? {
        var rect = NSRect(origin: .zero, size: self.size)
        if let cg = self.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg
        }
        guard let data = self.tiffRepresentation,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}
#endif
