import Foundation
import CoreGraphics
import ImageIO
import GenPlayerCore
#if os(macOS)
import AppKit
public typealias MediaArtworkImage = NSImage
#else
import UIKit
public typealias MediaArtworkImage = UIImage
#endif

/// Main-queue owner of one independent, cancellable artwork request.
/// Does not consult the user's playback engine or create VLC objects.
public final class IndependentMediaThumbnailGenerator {
    private var task: Task<Void, Never>?
    private var preview: MPVPlaybackPreviewProvider?
    private var completion: ((MediaArtworkImage?) -> Void)?
    private var request = UUID()
    private let completesOnCancel: Bool

    public init(completesOnCancel: Bool = false) { self.completesOnCancel = completesOnCancel }

    public func generateThumbnail(for url: URL, provider: String? = nil, serverID: String? = nil,
                                  path: String? = nil, itemID: String? = nil,
                                  isAudio: Bool? = nil,
                                  completion: @escaping (MediaArtworkImage?) -> Void) {
        cancel()
        self.completion = completion
        let token = request
        let scheme = url.scheme?.lowercased() ?? ""
        let provider = provider ?? (scheme == "ftps" ? "ftp" : scheme)
        if isAudio ?? (VideoFile.FileType.determineType(from: url) == .audio) {
            task = Task { @MainActor [weak self] in
                let data: Data?
                if url.isFileURL { data = try? await EmbeddedAudioArtworkReader.read(url) }
                else {
                    data = try? await RemoteAudioArtworkReader.read(url: url, provider: provider,
                        serverID: serverID, path: path, itemID: itemID)
                }
                guard !Task.isCancelled, let self, self.request == token else { return }
                self.finish(data.flatMap { MediaArtworkImage(data: $0) }, token: token)
            }
            return
        }
        let stream: MacMPVStream?
        if scheme == "smb" {
            let reader = SMBAudioRangeReader(url: url)
            stream = MacMPVStream(metadata: { try await reader.metadata().size },
                read: { try await reader.read(offset: $0, count: $1) })
        } else if ["ftp", "ftps", "sftp", "nfs"].contains(scheme) {
            let reader = FileAudioRangeReader(url: url, provider: provider,
                serverID: serverID, path: path, itemID: itemID)
            stream = MacMPVStream(metadata: { try await reader.metadata().size },
                read: { try await reader.read(offset: $0, count: $1) })
        } else { stream = nil }
        let server = serverID.flatMap { id in AppNetworkService.shared.savedServers.first { $0.id.uuidString == id } }
        var resolvedURL = RuntimeNetworkAddressResolver.runtimeURL(from: url)
        if provider == "webdav", let server, var parts = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false), parts.user == nil {
            parts.user = server.username; parts.password = server.passwordSecret
            resolvedURL = parts.url ?? resolvedURL
        }
        var options: [String: String] = [:]
        if provider == "vod" { options["user-agent"] = VODService.defaultUserAgent }
        if provider == "pan115" {
            options["user-agent"] = Pan115Manager.defaultUserAgent
            options["referrer"] = "https://115.com"
            if let cookie = server?.passwordSecret ?? server?.accessToken, !cookie.isEmpty {
                let header = "Cookie: " + cookie.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                options["http-header-fields"] = "%\(header.utf8.count)%\(header)"
            }
        }
        let reader = MPVPlaybackPreviewProvider(duration: 1, sourceSize: .zero) { _ in
            var config = MPVPlaybackEngine.Configuration(url: stream == nil ? resolvedURL : url,
                  start: 0, options: options, subtitles: [], stream: stream)
            config.startPercentage = 5
            return config
        }
        preview = reader
        reader.generate(snapshotPosition: 0) { [weak self] image in
            let result = image.map {
                #if os(macOS)
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                #else
                UIImage(cgImage: $0)
                #endif
            }
            self?.finish(result, token: token)
        }
    }

    public func cancel() {
        request = UUID()
        task?.cancel(); task = nil
        preview?.cancel(); preview = nil
        let callback = completion; completion = nil
        if completesOnCancel { callback?(nil) }
    }

    private func finish(_ image: MediaArtworkImage?, token: UUID) {
        guard request == token else { return }
        let callback = completion; completion = nil
        cancel()
        callback?(image)
    }

    deinit { task?.cancel(); preview?.cancel() }
}
