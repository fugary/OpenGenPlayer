import Foundation

public struct FavoriteStateRefreshPayload {
    public let serverId: UUID
    public let itemId: String
    public let seriesId: String?
    public let isFavorite: Bool

    public init(
        serverId: UUID,
        itemId: String,
        seriesId: String? = nil,
        isFavorite: Bool
    ) {
        self.serverId = serverId
        self.itemId = itemId
        self.seriesId = seriesId
        self.isFavorite = isFavorite
    }
}

public extension Notification.Name {
    static let remoteFavoriteStateDidChange = Notification.Name("GenPlayer.RemoteFavoriteStateDidChange")
    static let remoteItemDidDelete = Notification.Name("GenPlayer.RemoteItemDidDelete")
}

public struct RemoteItemDeletePayload {
    public let serverId: UUID
    public let itemId: String
    
    public init(serverId: UUID, itemId: String) {
        self.serverId = serverId
        self.itemId = itemId
    }
}

public enum FavoriteRefreshCenter {
    public static func updateRemoteItem(
        serverId: UUID,
        itemId: String,
        seriesId: String? = nil,
        isFavorite: Bool
    ) {
        let payload = FavoriteStateRefreshPayload(
            serverId: serverId,
            itemId: itemId,
            seriesId: seriesId,
            isFavorite: isFavorite
        )

        NotificationCenter.default.post(
            name: .remoteFavoriteStateDidChange,
            object: payload
        )
    }
}
