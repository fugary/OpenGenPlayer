import Foundation

// Extends the core EmbyItem with App-specific singletons
public extension EmbyItem {
    var bestVideoPixelCount: Int {
        guard let dimensions = bestVideoDimensions else { return 0 }
        return dimensions.width * dimensions.height
    }

    var videoResolutionLabel: String? {
        guard let dimensions = bestVideoDimensions else { return nil }
        let longSide = max(dimensions.width, dimensions.height)

        if longSide >= 3800 { return "4K" }
        if longSide >= 1900 { return "1080P" }
        if longSide >= 1200 { return "720P" }
        return nil
    }

    var premiereDateSortValue: Int? {
        if let rawValue = premiereDate?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawValue.isEmpty {
            let datePrefix = String(rawValue.prefix(10))
            let digits = datePrefix.filter { $0.isNumber }
            if digits.count >= 8,
               let value = Int(String(digits.prefix(8))) {
                return value
            }
            if let year = Int(String(rawValue.prefix(4))) {
                return year * 10000
            }
        }

        return productionYear.map { $0 * 10000 }
    }

    var productionYearSortValue: Int? {
        productionYear
    }

    var primaryFileSize: Int64? {
        mediaSources?.compactMap(\.size).first { $0 > 0 }
    }

    var compactPosterMetadataLine: String? {
        switch type {
        case "Movie":
            var parts: [String] = []
            if let year = productionYear {
                parts.append(String(year))
            }
            if let runtimeMinutes, runtimeMinutes > 0 {
                let hours = runtimeMinutes / 60
                let mins = runtimeMinutes % 60
                let runtimeStr = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
                parts.append(runtimeStr)
            }
            if let size = primaryFileSize, size > 0 {
                parts.append(appFormattedApproximateFileSize(size))
            } else if let resolution = videoResolutionLabel {
                parts.append(resolution)
            }
            return parts.isEmpty ? subtitle : parts.prefix(3).joined(separator: " • ")
        case "Series":
            var parts: [String] = []
            if let year = productionYear {
                parts.append(String(year))
            }
            // Build "n季 n集" / "nS nE" combined label
            if let seasons = childCount, seasons > 0 {
                let isChinese = NSLocalizedString("Season", comment: "") == "季"
                var countPart: String
                if isChinese {
                    countPart = "\(seasons) 季"
                    if let episodes = recursiveItemCount, episodes > 0 {
                        countPart += " \(episodes) 集"
                    }
                } else {
                    // Use compact abbreviation to avoid overflow on narrow poster cards
                    countPart = "\(seasons)S"
                    if let episodes = recursiveItemCount, episodes > 0 {
                        countPart += " \(episodes)E"
                    }
                }
                parts.append(countPart)
            } else if let officialRating, !officialRating.isEmpty {
                parts.append(officialRating)
            }
            return parts.isEmpty ? subtitle : parts.prefix(3).joined(separator: " • ")
        default:
            return subtitle
        }
    }

    private var bestVideoDimensions: (width: Int, height: Int)? {
        let dimensions = (mediaSources ?? []).compactMap { source -> (width: Int, height: Int)? in
            guard let stream = source.videoStream,
                  let width = stream.width,
                  let height = stream.height,
                  width > 0,
                  height > 0 else {
                return nil
            }
            return (width, height)
        }

        return dimensions.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
    }

    func primaryImageURL(server: ServerConfig, maxWidth: Int = 400) -> URL? {
        EmbyService.shared.getImageURL(
            server: server,
            itemId: id,
            imageType: "Primary",
            maxWidth: maxWidth,
            versionTag: primaryImageTag
        )
    }

    func backdropImageURL(server: ServerConfig, maxWidth: Int = 1920) -> URL? {
        EmbyService.shared.getImageURL(
            server: server,
            itemId: id,
            imageType: "Backdrop",
            maxWidth: maxWidth,
            versionTag: backdropImageTags?.first
        )
    }

    func logoImageURL(server: ServerConfig, maxWidth: Int = 600) -> URL? {
        if let logoTag = imageTags?["Logo"] {
            return EmbyService.shared.getImageURL(
                server: server,
                itemId: id,
                imageType: "Logo",
                maxWidth: maxWidth,
                versionTag: logoTag
            )
        }
        
        if let parentLogoId = parentLogoItemId, let parentLogoTag = parentLogoImageTag {
            return EmbyService.shared.getImageURL(
                server: server,
                itemId: parentLogoId,
                imageType: "Logo",
                maxWidth: maxWidth,
                versionTag: parentLogoTag
            )
        }
        
        // Emby episodes usually inherit the series logo automatically if parentLogoItemId is set.
        // We can optionally fallback to seriesId if parentLogoItemId is missing.
        if type == "Episode" || type == "Season", let seriesId = seriesId, !seriesId.isEmpty {
            return EmbyService.shared.getImageURL(
                server: server,
                itemId: seriesId,
                imageType: "Logo",
                maxWidth: maxWidth,
                versionTag: nil // We don't have the series logo tag, but Emby can resolve without it
            )
        }
        
        return nil
    }

    func spotlightBackdropImageURL(server: ServerConfig, maxWidth: Int = 1920) -> URL? {
        let ownBackdropURL: URL? = {
            guard let tags = backdropImageTags, !tags.isEmpty else { return nil }
            return backdropImageURL(server: server, maxWidth: maxWidth)
        }()
        let parentBackdropURL: URL? = {
            guard let parentId = parentBackdropItemId,
                  let tags = parentBackdropImageTags,
                  !tags.isEmpty else {
                return nil
            }
            return EmbyService.shared.getBackdropURL(
                server: server,
                itemId: parentId,
                versionTag: tags.first
            )
        }()

        switch type {
        case "Episode", "Season":
            return parentBackdropURL
                ?? ownBackdropURL
                ?? seriesPrimaryImageURL(server: server, maxWidth: 1000)
                ?? primaryImageURL(server: server, maxWidth: 1000)
                ?? landscapeImageURL(server: server)
        default:
            return ownBackdropURL
                ?? parentBackdropURL
                ?? primaryImageURL(server: server, maxWidth: 1000)
                ?? landscapeImageURL(server: server)
        }
    }

    func seriesPrimaryImageURL(server: ServerConfig, maxWidth: Int = 400) -> URL? {
        guard let seriesId, !seriesId.isEmpty else { return nil }
        return EmbyService.shared.getImageURL(
            server: server,
            itemId: seriesId,
            imageType: "Primary",
            maxWidth: maxWidth
        )
    }

    /// Get best available landscape image URL with fallback chain:
    /// 1. Own Backdrop → 2. Own Primary → 3. Parent Series Backdrop → 4. Own Primary (default)
    func landscapeImageURL(server: ServerConfig) -> URL? {
        if let tags = backdropImageTags, !tags.isEmpty {
            return backdropImageURL(server: server)
        } else if let parentId = parentBackdropItemId, let tags = parentBackdropImageTags, !tags.isEmpty {
            return EmbyService.shared.getBackdropURL(server: server, itemId: parentId, versionTag: tags.first)
        } else if let _ = primaryImageTag {
            return primaryImageURL(server: server, maxWidth: 800)
        } else if let parentId = seriesId, !parentId.isEmpty {
            return EmbyService.shared.getBackdropURL(server: server, itemId: parentId)
        }
        return primaryImageURL(server: server, maxWidth: 800)
    }
}

public extension EmbyLibrary {
    func primaryImageURL(server: ServerConfig, maxWidth: Int = 800) -> URL? {
        let imageItemId = primaryImageItemId ?? id
        guard primaryImageTag != nil || primaryImageItemId != nil else {
            return nil
        }
        return EmbyService.shared.getImageURL(
            server: server,
            itemId: imageItemId,
            imageType: "Primary",
            maxWidth: maxWidth,
            versionTag: primaryImageTag
        )
    }
}

public extension EmbyPerson {
    func primaryImageURL(server: ServerConfig, maxWidth: Int = 400) -> URL? {
        guard primaryImageTag != nil else { return nil }
        return EmbyService.shared.getImageURL(
            server: server,
            itemId: id,
            imageType: "Primary",
            maxWidth: maxWidth,
            versionTag: primaryImageTag
        )
    }
}
