import Foundation
#if os(iOS)
import UIKit
#endif

// Extends the core VideoFile (from GenPlayerCore) with App-specific Singleton routing
public extension VideoFile {
    // Conversion to Unified MediaItem
    var asMediaItem: MediaItem {
        let cachedArtwork = type == .audio
            ? thumbnailURL.flatMap { ImageCacheManager.shared.getImage(for: $0) }
            : nil

        var item = MediaItem(
            url: self.url,
            title: self.name,
            artist: nil,
            album: nil,
            artwork: cachedArtwork,
            isRemote: self.isRemote,
            jellyfinItemId: self.jellyfinItemId,
            jellyfinServerId: self.jellyfinServerId,
            serverType: self.serverType,
            seriesId: self.seriesId,
            seasonId: self.seasonId,
            startPosition: self.lastPlayedPosition,
            savedAudioTrackIndex: self.lastAudioTrack,
            savedSubtitleTrackIndex: self.lastSubtitleTrack
        )
        // Carry over transient server metadata for MediaInfo display
        item.serverMediaStreams = self.serverMediaStreams
        item.serverContainer = self.serverContainer
        item.serverSize = self.serverSize
        item.serverBitrate = self.serverBitrate
        item.serverPath = self.serverPath
        item.remotePlaybackMethod = self.remotePlaybackMethod
        item.shouldResetRemotePlayedStateOnPlaybackStart = self.shouldResetRemotePlayedStateOnPlaybackStart
        item.externalSubtitleCandidates = self.externalSubtitleCandidates
        item.preferredAudioTrackQuery = self.preferredAudioTrackQuery
        item.preferredSubtitleTrackQuery = self.preferredSubtitleTrackQuery
        item.preferredAudioTrackOrdinal = self.preferredAudioTrackOrdinal
        item.preferredSubtitleTrackOrdinal = self.preferredSubtitleTrackOrdinal
        item.preferredPlaybackQualityID = self.preferredPlaybackQualityID
        item.availablePlaybackQualityOptions = self.availablePlaybackQualityOptions
        item.videoFile = self
        if self.disableSubtitlesOnStart {
            item.savedSubtitleTrackIndex = -1
        }
        return item
    }

    // Matches the file to a known ServerConfig from AppNetworkService
    var resolvedServer: ServerConfig? {
        let savedServers = AppNetworkService.shared.savedServers
        
        // A. Match by saved server ID (also used for SMB/WebDAV in this app)
        if let serverIdString = jellyfinServerId, let serverUUID = UUID(uuidString: serverIdString) {
            if let match = savedServers.first(where: { $0.id == serverUUID }) {
                return match
            }
        }
        
        guard isRemote else { return nil }

        // B. Match by host/address with hostname<->IP normalization.
        guard let rawHost = url.host else { return nil }
        // Note: ServerHostResolver is now mostly internal to core, so we simulate exact match for App level parsing 
        // We will just do a standard loose match here if needed, or we must expose ServerHostResolver
        let fileHosts = [rawHost, rawHost.lowercased()] // Simplified for compilation bridging
        
        let preferredType = serverType // fallback not fully implemented here
        
        let isPortMatch = { (server: ServerConfig) -> Bool in
            let serverPort: Int
            if let p = server.port {
                serverPort = p
            } else if let parsedPort = URLComponents(string: server.fullURL)?.port {
                serverPort = parsedPort
            } else {
                serverPort = ServerConfig.defaultPort(for: server.type, useSSL: server.useSSL)
            }
            
            if let fPort = self.url.port {
                return fPort == serverPort
            } else {
                let scheme = self.url.scheme?.lowercased()
                if scheme == "https" && serverPort != 443 { return false }
                if scheme == "http" && serverPort != 80 { return false }
                return true
            }
        }
        
        // 1. Strict match: Host AND Port
        if let preferredType {
            if let match = savedServers.first(where: { server in
                server.type == preferredType &&
                (fileHosts.contains(server.address.lowercased())) &&
                isPortMatch(server)
            }) {
                return match
            }
        }
        
        if let match = savedServers.first(where: { server in
            fileHosts.contains(server.address.lowercased()) &&
            isPortMatch(server)
        }) {
            return match
        }
        
        return nil
    }

    var thumbnailURL: URL? {
        if let customArtworkURL {
            return customArtworkURL
        }
        let hasRemoteOrigin = isRemote || jellyfinServerId != nil || serverType != nil
        let resolvedType: ServerConfig.ServerType? = hasRemoteOrigin ? (resolvedServer?.type ?? serverType) : nil

        if (resolvedType?.isCloudDrive == true || resolvedType == .googledrive) && (type == .audio || type == .video) {
            return nil
        }

        if hasRemoteOrigin, let config = resolvedServer {
            switch config.type {
            case .jellyfin:
                if let seriesId, !seriesId.isEmpty {
                    return JellyfinService.shared.getImageURL(server: config, itemId: seriesId, imageType: "Primary", maxWidth: 400)
                }
                if let itemId = jellyfinItemId {
                    return JellyfinService.shared.getImageURL(server: config, itemId: itemId, imageType: "Primary", maxWidth: 400)
                }
            case .emby:
                if let seriesId, !seriesId.isEmpty {
                    return EmbyService.shared.getImageURL(server: config, itemId: seriesId, imageType: "Primary", maxWidth: 400)
                }
                if let itemId = jellyfinItemId {
                    return EmbyService.shared.getImageURL(server: config, itemId: itemId, imageType: "Primary", maxWidth: 400)
                }
            case .plex, .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs, .iptv, .vod:
                 break
            }
        }
        
        if type == .audio {
            if url.isFileURL {
                return url
            }
            if let resolvedType {
                switch resolvedType {
                case .smb, .webdav, .ftp, .sftp, .nfs:
                    return url
                case .alist:
                    return nil
                default:
                    break
                }
            }
            return nil
        }
        if type != .video && type != .image {
            return nil
        }

        return url
    }
}
