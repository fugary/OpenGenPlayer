import Foundation
@_exported import GenPlayerCore

private func plexImageVersionTag(from updatedAt: Date?) -> String? {
    guard let updatedAt else { return nil }
    return String(Int(updatedAt.timeIntervalSince1970.rounded(.down)))
}

public extension PlexLibrary {
    var imageVersionTag: String? {
        plexImageVersionTag(from: updatedAt)
    }

    func imageURL(server: ServerConfig, imagePath: String?) -> URL? {
        PlexService.shared.getImageURL(server: server, imagePath: imagePath, versionTag: imageVersionTag)
    }
}

public extension PlexPerson {
    var imageVersionTag: String? {
        plexImageVersionTag(from: updatedAt)
    }

    func primaryImageURL(server: ServerConfig) -> URL? {
        PlexService.shared.getImageURL(server: server, imagePath: thumb, versionTag: imageVersionTag)
    }
}

public extension PlexItem {
    var imageVersionTag: String? {
        plexImageVersionTag(from: updatedAt)
    }

    func posterImageURL(server: ServerConfig) -> URL? {
        PlexService.shared.getImageURL(server: server, imagePath: posterPath, versionTag: imageVersionTag)
    }

    func backdropImageURL(server: ServerConfig) -> URL? {
        PlexService.shared.getImageURL(server: server, imagePath: backdropPath, versionTag: imageVersionTag)
    }

    func primaryImageURL(server: ServerConfig) -> URL? {
        imageURL(server: server, imagePath: thumb)
    }

    func landscapeImageURL(server: ServerConfig) -> URL? {
        backdropImageURL(server: server) ?? primaryImageURL(server: server) ?? posterImageURL(server: server)
    }

    func imageURL(server: ServerConfig, imagePath: String?) -> URL? {
        PlexService.shared.getImageURL(server: server, imagePath: imagePath, versionTag: imageVersionTag)
    }
}
