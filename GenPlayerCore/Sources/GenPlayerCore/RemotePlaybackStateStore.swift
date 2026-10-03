import Foundation
import Combine

public struct RemotePlaybackStateSnapshot: Equatable {
    public let playbackPositionTicks: Int64?
    public let playedPercentage: Double?
    public let played: Bool
    public let updatedAt: Date

    public init(
        playbackPositionTicks: Int64?,
        playedPercentage: Double?,
        played: Bool,
        updatedAt: Date = Date()
    ) {
        self.playbackPositionTicks = playbackPositionTicks
        self.playedPercentage = playedPercentage.map { min(max($0, 0), 100) }
        self.played = played
        self.updatedAt = updatedAt
    }

    public static func fromPlaybackPosition(
        position: TimeInterval,
        duration: TimeInterval
    ) -> RemotePlaybackStateSnapshot {
        let clampedPosition = max(position, 0)
        let resolvedDuration = max(duration, 0)
        let isFinished = HistoryService.playbackIsFinished(
            position: clampedPosition,
            duration: resolvedDuration
        )

        let percent: Double?
        if resolvedDuration > 0 {
            let normalized = HistoryService.normalizedPlaybackProgress(
                position: isFinished ? resolvedDuration : clampedPosition,
                duration: resolvedDuration
            )
            percent = normalized * 100
        } else {
            percent = isFinished ? 100 : nil
        }

        let ticks: Int64?
        if isFinished, resolvedDuration > 0 {
            ticks = Int64(resolvedDuration * 10_000_000.0)
        } else if clampedPosition > 0 {
            ticks = Int64(clampedPosition * 10_000_000.0)
        } else {
            ticks = isFinished ? 0 : nil
        }

        return RemotePlaybackStateSnapshot(
            playbackPositionTicks: ticks,
            playedPercentage: percent,
            played: isFinished
        )
    }

    public static func manualPlayedState(
        played: Bool,
        runtimeTicks: Int64? = nil
    ) -> RemotePlaybackStateSnapshot {
        RemotePlaybackStateSnapshot(
            playbackPositionTicks: played ? runtimeTicks : 0,
            playedPercentage: played ? 100 : 0,
            played: played
        )
    }
}

private struct RemotePlaybackStateKey: Hashable {
    let serverId: UUID
    let itemId: String
}

public struct PlaybackStateRefreshPayload {
    public let serverId: UUID
    public let itemId: String
    public let seriesId: String?
    public let seasonId: String?
    public let snapshot: RemotePlaybackStateSnapshot

    public init(
        serverId: UUID,
        itemId: String,
        seriesId: String? = nil,
        seasonId: String? = nil,
        snapshot: RemotePlaybackStateSnapshot
    ) {
        self.serverId = serverId
        self.itemId = itemId
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.snapshot = snapshot
    }
}

public final class RemotePlaybackStateStore: ObservableObject {
    public static let shared = RemotePlaybackStateStore()

    @Published private var snapshots: [RemotePlaybackStateKey: RemotePlaybackStateSnapshot] = [:]
    private let ttl: TimeInterval = 300

    private init() {}

    public func snapshot(serverId: UUID, itemId: String) -> RemotePlaybackStateSnapshot? {
        guard !itemId.isEmpty else { return nil }

        let key = RemotePlaybackStateKey(serverId: serverId, itemId: itemId)
        guard let snapshot = snapshots[key] else { return nil }
        guard Date().timeIntervalSince(snapshot.updatedAt) <= ttl else { return nil }
        return snapshot
    }

    public func apply(_ payload: PlaybackStateRefreshPayload) {
        cleanupExpiredSnapshots()
        let key = RemotePlaybackStateKey(serverId: payload.serverId, itemId: payload.itemId)
        snapshots[key] = payload.snapshot
    }

    private func cleanupExpiredSnapshots() {
        let now = Date()
        snapshots = snapshots.filter { _, value in
            now.timeIntervalSince(value.updatedAt) <= ttl
        }
    }
}

public extension Notification.Name {
    public static let remotePlaybackStateDidChange = Notification.Name("GenPlayer.RemotePlaybackStateDidChange")
    public static let macServerPlaybackSyncRequest = Notification.Name("GenPlayer.MacServerPlaybackSyncRequest")
    public static let macNavigateToSettingsAbout = Notification.Name("GenPlayer.MacNavigateToSettingsAbout")
    public static let macNavigateToDownloads = Notification.Name("GenPlayer.MacNavigateToDownloads")
}

public struct MacServerPlaybackSyncPayload {
    public let serverType: ServerConfig.ServerType
    public let serverId: String
    public let itemId: String
    public let userId: String
    public let token: String
    public let positionTicks: Int64
    public let isPaused: Bool
    public let eventName: String // "playing", "progress", "stopped"
    
    public init(serverType: ServerConfig.ServerType, serverId: String, itemId: String, userId: String, token: String, positionTicks: Int64, isPaused: Bool, eventName: String) {
        self.serverType = serverType
        self.serverId = serverId
        self.itemId = itemId
        self.userId = userId
        self.token = token
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.eventName = eventName
    }
}

public enum PlaybackRefreshCenter {
    public static func recordPlaybackStop(
        for item: MediaItem,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) {
        guard let payload = makePayload(
            for: item,
            snapshot: RemotePlaybackStateSnapshot.fromPlaybackPosition(
                position: currentTime,
                duration: duration
            )
        ) else {
            return
        }

        publish(payload)
    }

    public static func updateRemoteItem(
        serverId: UUID,
        itemId: String,
        seriesId: String? = nil,
        seasonId: String? = nil,
        snapshot: RemotePlaybackStateSnapshot
    ) {
        publish(
            PlaybackStateRefreshPayload(
                serverId: serverId,
                itemId: itemId,
                seriesId: seriesId,
                seasonId: seasonId,
                snapshot: snapshot
            )
        )
    }

    private static func makePayload(
        for item: MediaItem,
        snapshot: RemotePlaybackStateSnapshot
    ) -> PlaybackStateRefreshPayload? {
        let itemId = item.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serverIdString = item.jellyfinServerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !itemId.isEmpty, let serverId = UUID(uuidString: serverIdString) else {
            return nil
        }

        return PlaybackStateRefreshPayload(
            serverId: serverId,
            itemId: itemId,
            seriesId: item.seriesId,
            seasonId: item.seasonId,
            snapshot: snapshot
        )
    }

    private static func publish(_ payload: PlaybackStateRefreshPayload) {
        RemotePlaybackStateStore.shared.apply(payload)
        NotificationCenter.default.post(
            name: .remotePlaybackStateDidChange,
            object: payload
        )
    }
}

public extension JellyfinUserData {
    public static func merged(
        _ base: JellyfinUserData?,
        playbackState: RemotePlaybackStateSnapshot?
    ) -> JellyfinUserData? {
        guard let playbackState else { return base }

        return JellyfinUserData(
            playbackPositionTicks: playbackState.playbackPositionTicks ?? base?.playbackPositionTicks,
            playCount: base?.playCount,
            isFavorite: base?.isFavorite,
            played: playbackState.played,
            playedPercentage: playbackState.playedPercentage ?? base?.playedPercentage,
            lastPlayedDate: base?.lastPlayedDate
        )
    }
}

public extension EmbyUserData {
    public static func merged(
        _ base: EmbyUserData?,
        playbackState: RemotePlaybackStateSnapshot?
    ) -> EmbyUserData? {
        guard let playbackState else { return base }

        return EmbyUserData(
            playbackPositionTicks: playbackState.playbackPositionTicks ?? base?.playbackPositionTicks,
            playCount: base?.playCount,
            isFavorite: base?.isFavorite,
            played: playbackState.played,
            playedPercentage: playbackState.playedPercentage ?? base?.playedPercentage,
            lastPlayedDate: base?.lastPlayedDate
        )
    }
}
