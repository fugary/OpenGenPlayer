#if os(macOS)
import Foundation
import GenPlayerCore

public struct DefaultMacPlaylistResolver: MacPlaylistResolver {
    public init() {}
    
    public func resolvePlaylist(for file: VideoFile) async -> [VideoFile]? {
        var files: [VideoFile]? = nil
        let targetType: VideoFile.FileType = file.type == .audio ? .audio : .video
        
        // 1. Try remote season playlist (Jellyfin / Emby / Plex)
        if file.isRemote,
           let rawServer = file.resolvedServer ?? AppNetworkService.shared.servers.first(where: { $0.id.uuidString == file.jellyfinServerId }),
           (rawServer.type == .jellyfin || rawServer.type == .emby || rawServer.type == .plex) {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            let token = server.accessToken ?? ""
            let userId = server.userId ?? ""
            
            var targetSeasonId = file.seasonId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if (targetSeasonId == nil || targetSeasonId?.isEmpty == true),
               let itemId = file.jellyfinItemId?.nilIfEmpty ?? file.id.nilIfEmpty {
                if server.type == .jellyfin {
                    if let item = try? await JellyfinService.shared.getItemDetails(server: server, itemId: itemId, token: token) {
                        targetSeasonId = item.seasonId
                    }
                } else if server.type == .emby {
                    if let item = try? await EmbyService.shared.getItemDetails(server: server, userId: userId, itemId: itemId, token: token) {
                        targetSeasonId = item.seasonId
                    }
                } else if server.type == .plex {
                    if let item = try? await PlexService.shared.getMetadataItem(server: server, itemId: itemId) {
                        targetSeasonId = item.parentRatingKey ?? (item.type.lowercased() == "season" ? item.id : nil)
                    }
                }
            }
            
            if let seasonId = targetSeasonId, !seasonId.isEmpty {
                if server.type == .jellyfin {
                    if let response = try? await JellyfinService.shared.getItems(server: server, userId: userId, token: token, libraryId: seasonId, includeTypes: ["Episode"], sortBy: "IndexNumber") {
                        files = response.items.filter { $0.type == "Episode" }.compactMap { item in
                            let preferredSource = JellyfinService.shared.preferredPlaybackSource(from: item.mediaSources ?? []) ?? item.mediaSources?.first
                            guard let streamURL = JellyfinService.shared.resolvePlaybackURL(server: server, itemId: item.id, token: token, mediaSource: preferredSource) else { return nil }
                            var f = VideoFile.fromJellyfinItem(item: item, server: server, streamURL: streamURL)
                            f.url = streamURL
                            return f
                        }
                    }
                } else if server.type == .emby {
                    if let response = try? await EmbyService.shared.getItems(server: server, userId: userId, token: token, parentId: seasonId, includeItemTypes: "Episode", sortBy: "IndexNumber") {
                        files = response.items.filter { $0.type == "Episode" }.compactMap { item in
                            let preferredSource = EmbyService.shared.preferredPlaybackSource(from: item.mediaSources ?? []) ?? item.mediaSources?.first
                            guard let streamURL = EmbyService.shared.resolvePlaybackURL(server: server, itemId: item.id, token: token, mediaSource: preferredSource) else { return nil }
                            var f = VideoFile.fromEmbyItem(item: item, server: server, streamURL: streamURL)
                            f.url = streamURL
                            return f
                        }
                    }
                } else if server.type == .plex {
                    if let items = try? await PlexService.shared.getChildren(server: server, itemId: seasonId) {
                        files = items.compactMap { PlexService.shared.buildPlayableVideoFile(server: server, item: $0) }
                    }
                }
            }
        }
        
        // 2. Try remote folder playlist (SMB, WebDAV, FTP, SFTP, NFS)
        if files == nil, file.isRemote,
           let rawServer = file.resolvedServer,
           rawServer.type.isFileServer {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            let parentPath = file.remoteFolderPath
            if let networkFiles = try? await AppNetworkService.shared.fetchContents(for: server, at: parentPath) {
                files = networkFiles.filter { $0.type == targetType }
                files?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        
        // 3. Try local folder playlist
        if files == nil && !file.isRemote {
            let directoryURL = file.url.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
                files = contents.compactMap { url -> VideoFile? in
                    let resolvedType = VideoFile.FileType.determineType(from: url)
                    guard resolvedType == targetType else { return nil }
                    let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    return VideoFile(
                        name: url.lastPathComponent,
                        url: url,
                        type: resolvedType,
                        size: Int64(resourceValues?.fileSize ?? 0),
                        date: resourceValues?.contentModificationDate ?? Date(),
                        isRemote: false
                    )
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        
        // Apply findings
        if var playlistFiles = files, !playlistFiles.isEmpty {
            if let matchedIndex = playlistFiles.firstIndex(where: { $0.name == file.name || $0.id == file.id }) {
                playlistFiles[matchedIndex] = file
                return Array(playlistFiles.prefix(100))
            } else {
                playlistFiles.append(file)
                return Array(playlistFiles.prefix(100))
            }
        }
        
        return nil
    }
}
#endif
