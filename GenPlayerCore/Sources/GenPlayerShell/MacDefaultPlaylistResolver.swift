#if os(macOS)
import Foundation
import GenPlayerCore

public struct MacDefaultPlaylistResolver: MacPlaylistResolver {
    public init() {}
    
    public func resolvePlaylist(for file: VideoFile) async -> [VideoFile]? {
        var files: [VideoFile]? = nil
        let targetType: VideoFile.FileType = file.type == .audio ? .audio : .video
        
        // 1. Try remote season / album playlist (Jellyfin / Emby / Plex)
        if file.isRemote,
           let rawServer = resolveServer(for: file) ?? file.resolvedServer,
           (rawServer.type == .jellyfin || rawServer.type == .emby || rawServer.type == .plex) {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            
            if file.type == .video {
                var targetSeasonId = file.seasonId?.trimmingCharacters(in: .whitespacesAndNewlines)
                if (targetSeasonId == nil || targetSeasonId?.isEmpty == true),
                   let itemId = file.jellyfinItemId?.nilIfEmpty ?? file.id.nilIfEmpty {
                    if let node = try? await fetchMacMediaItem(server: server, nodeId: itemId) {
                        targetSeasonId = node.seasonId ?? (node.collectionType?.lowercased() == "season" ? node.id : nil)
                    }
                }
                
                if let seasonId = targetSeasonId, !seasonId.isEmpty {
                    if server.type == .jellyfin || server.type == .emby {
                        if let userId = try? await resolvedMediaLibraryUserId(server: server), !userId.isEmpty {
                            let urlString = "\(baseURL)/Users/\(userId)/Items?ParentId=\(seasonId)&IncludeItemTypes=Episode&SortBy=IndexNumber&Fields=\(macJellyfinItemFields)"
                            if let rawURL = URL(string: urlString) {
                                let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
                                var request = URLRequest(url: url)
                                applyMediaLibraryHeaders(to: &request, server: server)
                                if let (data, response) = try? await URLSession.shared.data(for: request),
                                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let items = json["Items"] as? [[String: Any]] {
                                    let parsedNodes = parseJellyfinItems(items, baseURL: baseURL, server: server)
                                    files = parsedNodes.map { macMakeVideoFile(for: $0, server: server) }
                                }
                            }
                        }
                    } else if server.type == .plex {
                        let seasonNode = MacMediaLibraryNode(
                            id: seasonId,
                            name: "",
                            type: .video,
                            isFolder: true,
                            remotePath: seasonId.hasPrefix("/") ? (seasonId.hasSuffix("/children") ? seasonId : "\(seasonId)/children") : "/library/metadata/\(seasonId)/children"
                        )
                        if let episodeNodes = try? await fetchNodes(server: server, parentNode: seasonNode) {
                            files = episodeNodes.map { macMakeVideoFile(for: $0, server: server) }
                        }
                    }
                }
            } else if file.type == .audio {
                // Audio Album
                var targetAlbumId = file.seasonId?.trimmingCharacters(in: .whitespacesAndNewlines)
                if (targetAlbumId == nil || targetAlbumId?.isEmpty == true),
                   let itemId = file.jellyfinItemId?.nilIfEmpty ?? file.id.nilIfEmpty {
                    if let node = try? await fetchMacMediaItem(server: server, nodeId: itemId) {
                        targetAlbumId = node.seasonId ?? (node.collectionType?.lowercased() == "musicalbum" || node.collectionType?.lowercased() == "album" ? node.id : nil)
                    }
                }
                
                if let albumId = targetAlbumId, !albumId.isEmpty {
                    if server.type == .jellyfin || server.type == .emby {
                        if let userId = try? await resolvedMediaLibraryUserId(server: server), !userId.isEmpty {
                            let urlString = "\(baseURL)/Users/\(userId)/Items?ParentId=\(albumId)&IncludeItemTypes=Audio&SortBy=IndexNumber&Fields=\(macJellyfinItemFields)"
                            if let rawURL = URL(string: urlString) {
                                let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
                                var request = URLRequest(url: url)
                                applyMediaLibraryHeaders(to: &request, server: server)
                                if let (data, response) = try? await URLSession.shared.data(for: request),
                                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let items = json["Items"] as? [[String: Any]] {
                                    let parsedNodes = parseJellyfinItems(items, baseURL: baseURL, server: server)
                                    files = parsedNodes.map { macMakeVideoFile(for: $0, server: server) }
                                }
                            }
                        }
                    } else if server.type == .plex {
                        let albumNode = MacMediaLibraryNode(
                            id: albumId,
                            name: "",
                            type: .audio,
                            isFolder: true,
                            remotePath: albumId.hasPrefix("/") ? (albumId.hasSuffix("/children") ? albumId : "\(albumId)/children") : "/library/metadata/\(albumId)/children"
                        )
                        if let trackNodes = try? await fetchNodes(server: server, parentNode: albumNode) {
                            files = trackNodes.map { macMakeVideoFile(for: $0, server: server) }
                        }
                    }
                }
            }
        }
        
        // 2. Try remote folder playlist (SMB, WebDAV, FTP, SFTP, NFS)
        if files == nil, file.isRemote,
           let rawServer = resolveServer(for: file) ?? file.resolvedServer,
           rawServer.type.isFileServer {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            let parentPath = file.remoteFolderPath
            if let networkFiles = try? await AppNetworkService.shared.fetchContents(for: server, at: parentPath) {
                files = networkFiles.filter { $0.type == targetType }
                files?.sort { ($0.name as NSString).localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        
        // 3. Try local folder playlist
        if files == nil && !file.isRemote {
            let directoryURL = file.url.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
                let resolved = contents.compactMap { url -> VideoFile? in
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
                if !resolved.isEmpty {
                    files = resolved
                }
            }
        }
        
        // Apply findings
        if var playlistFiles = files, !playlistFiles.isEmpty {
            if let matchedIndex = playlistFiles.firstIndex(where: { $0.name == file.name || $0.id == file.id || $0.jellyfinItemId == file.jellyfinItemId || $0.url == file.url }) {
                playlistFiles[matchedIndex] = file
            } else {
                playlistFiles.append(file)
            }
            return playlistFiles
        }
        
        return nil
    }
    
    private func resolveServer(for file: VideoFile) -> ServerConfig? {
        if let id = file.jellyfinServerId, let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString == id }) {
            return server
        }
        if let host = file.url.host {
            for server in AppNetworkService.shared.servers {
                if server.address.lowercased() == host.lowercased() {
                    return server
                }
            }
        }
        return nil
    }
}
#endif
