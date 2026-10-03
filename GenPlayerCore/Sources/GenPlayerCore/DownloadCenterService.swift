import Foundation
import Darwin
import Combine
#if os(iOS)
import UIKit
#endif

@MainActor
public class DownloadCenterService: ObservableObject {
    public static let shared = DownloadCenterService()

    public struct DownloadedStorageSummary {
        public let fileCount: Int
        public let recordCount: Int
        public let totalBytes: Int64
        
        public init(fileCount: Int, recordCount: Int, totalBytes: Int64) {
            self.fileCount = fileCount
            self.recordCount = recordCount
            self.totalBytes = totalBytes
        }
    }

    @Published public private(set) var tasks: [DownloadTaskItem] = []

    private enum TerminationReason {
        case pause
        case cancel
    }

    private struct DownloadSpeedSample {
        var lastObservedBytes: Int64
        var lastPublishedAt: Date
        var sampledBytes: Int64
        var lastSpeedSampleAt: Date
        var smoothedSpeedBytesPerSec: Double

        init(initialBytes: Int64, now: Date = Date()) {
            lastObservedBytes = initialBytes
            lastPublishedAt = now
            sampledBytes = 0
            lastSpeedSampleAt = now
            smoothedSpeedBytesPerSec = 0
        }
    }

    private let networkService = AppNetworkService.shared
    private let backgroundDownloadManager = BackgroundDownloadSessionManager.shared
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var activeHTTPDownloads: [UUID: ManagedHTTPDownload] = [:]
    private var backgroundSpeedSamples: [UUID: DownloadSpeedSample] = [:]
    private var terminationReasons: [UUID: TerminationReason] = [:]
    private let persistenceURL: URL
    private let persistenceQueue = DispatchQueue(label: "com.genplayer.download.persistence", qos: .utility)
    private var lifecycleObservers: [NSObjectProtocol] = []
    private static let missingLocalFileMessageKey = "Downloaded file was removed from local storage."
    
    #if os(iOS)
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    public var maxConcurrentDownloads: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
            return value > 0 ? value : 3
        }
        set {
            let clamped = max(1, min(5, newValue))
            UserDefaults.standard.set(clamped, forKey: "maxConcurrentDownloads")
            drainQueue()
        }
    }

    public func drainQueue() {
        let currentlyDownloadingCount = tasks.filter { $0.status == .downloading }.count
        let availableSlots = maxConcurrentDownloads - currentlyDownloadingCount
        guard availableSlots > 0 else { return }

        let queuedTasks = tasks
            .filter { $0.status == .queued }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.groupIndex < $1.groupIndex
                }
                return $0.createdAt < $1.createdAt
            }

        for task in queuedTasks.prefix(availableSlots) {
            guard let server = networkService.servers.first(where: { $0.id == task.serverId }) else {
                updateTask(task.id) {
                    $0.status = .failed
                    $0.errorMessage = "Server not found"
                }
                continue
            }
            startDownload(for: task.id, server: server)
        }
    }

    private init() {
        let fileManager = FileManager.default
        let appDir = Self.makePersistenceDirectory(fileManager: fileManager)
        let newPersistenceURL = appDir.appendingPathComponent("download_tasks.json")
        Self.migrateLegacyPersistenceIfNeeded(fileManager: fileManager, to: newPersistenceURL)
        persistenceURL = newPersistenceURL
        backgroundDownloadManager.delegate = self
        loadPersistedTasks()
        reconcileMissingLocalFiles()
        configureLifecycleObservers()
        restoreBackgroundDownloads()
    }

    private static func makePersistenceDirectory(fileManager: FileManager) -> URL {
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = appSupport.appendingPathComponent("GenPlayer", isDirectory: true)
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
            return appDir
        }

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fallbackDir = documents.appendingPathComponent("GenPlayer", isDirectory: true)
        try? fileManager.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        return fallbackDir
    }

    private static func migrateLegacyPersistenceIfNeeded(fileManager: FileManager, to newURL: URL) {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let legacyDir = documents.appendingPathComponent("GenPlayer", isDirectory: true)
        let legacyURL = legacyDir.appendingPathComponent("download_tasks.json")
        if !fileManager.fileExists(atPath: newURL.path),
           fileManager.fileExists(atPath: legacyURL.path) {
            do {
                try fileManager.moveItem(at: legacyURL, to: newURL)
            } catch {
                try? fileManager.copyItem(at: legacyURL, to: newURL)
            }
        }

        if let entries = try? fileManager.contentsOfDirectory(atPath: legacyDir.path), entries.isEmpty {
            try? fileManager.removeItem(at: legacyDir)
        }
    }

    public var activeTasks: [DownloadTaskItem] { tasks.filter { $0.isActive } }
    public var completedTasks: [DownloadTaskItem] { tasks.filter { $0.status == .completed } }
    public var failedTasks: [DownloadTaskItem] { tasks.filter { $0.status == .failed || $0.status == .canceled } }

    public var jobs: [DownloadJobGroup] {
        let grouped = Dictionary(grouping: tasks) { $0.jobId }
        return grouped.compactMap { jobId, groupedTasks in
            guard let anchor = groupedTasks.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            return DownloadJobGroup(
                id: jobId,
                kind: anchor.jobKind,
                sourceType: anchor.sourceType,
                title: anchor.groupTitle ?? anchor.displayTitle,
                groupTitle: anchor.groupTitle,
                serverId: anchor.serverId,
                serverName: anchor.serverName,
                createdAt: anchor.createdAt,
                tasks: groupedTasks.sorted {
                    if $0.groupIndex == $1.groupIndex {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.groupIndex < $1.groupIndex
                }
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public var activeJobs: [DownloadJobGroup] { jobs.filter { $0.bucket == .active } }
    public var completedJobs: [DownloadJobGroup] { jobs.filter { $0.bucket == .completed } }
    public var failedJobs: [DownloadJobGroup] { jobs.filter { $0.bucket == .failed } }

    public func downloadedStorageSummary() -> DownloadedStorageSummary {
        let completedTasks = tasks.filter { $0.status == .completed }
        let uniqueURLs = uniqueExistingLocalFileURLs(for: completedTasks)
        let totalBytes = uniqueURLs.reduce(Int64(0)) { partialResult, url in
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partialResult + Int64(fileSize)
        }

        return DownloadedStorageSummary(
            fileCount: uniqueURLs.count,
            recordCount: completedTasks.count,
            totalBytes: totalBytes
        )
    }

    public func isTrackedLocalDownload(_ url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        return tasks.contains { task in
            guard task.status == .completed,
                  let path = task.localFilePath,
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == standardizedPath
        }
    }

    public func isDownloaded(serverId: UUID, remotePath: String) -> Bool {
        guard let task = bestTask(serverId: serverId, remotePath: remotePath) else { return false }
        guard task.status == .completed, let path = task.localFilePath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    public func isDownloaded(file: VideoFile) -> Bool {
        guard file.isRemote,
              let serverIdString = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdString) else {
            return false
        }

        if let remoteItemId = file.jellyfinItemId,
           isDownloaded(serverId: serverId, remoteItemId: remoteItemId) {
            return true
        }

        return isDownloaded(serverId: serverId, remotePath: file.url.path)
    }

    public func localFileURL(for file: VideoFile) -> URL? {
        guard file.isRemote,
              let serverIdString = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdString) else {
            return nil
        }

        if let remoteItemId = file.jellyfinItemId,
           let url = localFileURL(serverId: serverId, remoteItemId: remoteItemId) {
            return url
        }

        return localFileURL(serverId: serverId, remotePath: file.url.path)
    }

    public func localPlaybackFile(for file: VideoFile) -> VideoFile? {
        guard let localURL = localFileURL(for: file) else { return nil }

        let resourceValues = try? localURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let resolvedType = VideoFile.FileType.determineType(from: localURL)
        let playbackType = resolvedType == .unknown ? file.type : resolvedType

        var localFile = VideoFile(
            name: file.name,
            url: localURL,
            type: playbackType,
            size: Int64(resourceValues?.fileSize ?? Int(clamping: file.size)),
            date: resourceValues?.contentModificationDate ?? file.date,
            isRemote: false,
            duration: file.duration,
            lastPlayedPosition: file.lastPlayedPosition,
            lastAudioTrack: file.lastAudioTrack,
            lastSubtitleTrack: file.lastSubtitleTrack,
            jellyfinItemId: file.jellyfinItemId,
            jellyfinServerId: file.jellyfinServerId,
            serverType: file.serverType,
            itemCount: file.itemCount,
            seriesId: file.seriesId,
            seasonId: file.seasonId,
            preferredAudioTrackQuery: file.preferredAudioTrackQuery,
            preferredSubtitleTrackQuery: file.preferredSubtitleTrackQuery,
            disableSubtitlesOnStart: file.disableSubtitlesOnStart,
            externalSubtitleCandidates: file.externalSubtitleCandidates
        )
        localFile.preferredAudioTrackOrdinal = file.preferredAudioTrackOrdinal
        localFile.preferredSubtitleTrackOrdinal = file.preferredSubtitleTrackOrdinal
        localFile.serverMediaStreams = file.serverMediaStreams
        localFile.serverContainer = file.serverContainer
        localFile.serverSize = file.serverSize
        localFile.serverBitrate = file.serverBitrate
        localFile.serverPath = file.serverPath
        return localFile
    }

    public func completedTask(for localFileURL: URL) -> DownloadTaskItem? {
        let targetURL = localFileURL.standardizedFileURL.resolvingSymlinksInPath()
        let targetPath = targetURL.path
        let targetFileName = localFileURL.lastPathComponent
        return tasks.first { task in
            guard task.status == .completed,
                  let localPath = task.localFilePath,
                  !localPath.isEmpty else {
                return false
            }
            let taskURL = URL(fileURLWithPath: localPath).standardizedFileURL.resolvingSymlinksInPath()
            if taskURL.path == targetPath {
                return true
            }
            // 相对路径匹配：应对 Documents 目录迁移/重装场景
            if taskURL.lastPathComponent == targetFileName {
                let rel1 = DownloadTaskItem.relativeLocalPath(forRawPath: targetPath)
                let rel2 = DownloadTaskItem.relativeLocalPath(forRawPath: taskURL.path)
                if let rel1, let rel2, rel1 == rel2 {
                    return true
                }
            }
            return false
        }
    }


    public func hydratedPlaybackFile(for localFile: VideoFile) -> VideoFile? {
        guard localFile.url.isFileURL else { return nil }
        guard let task = completedTask(for: localFile.url) else { return nil }

        let server = AppNetworkService.shared.servers.first(where: { $0.id == task.serverId })
        let serverType = server?.type ?? task.sourceType.serverType

        var hydrated = localFile
        if hydrated.jellyfinItemId == nil || hydrated.jellyfinItemId?.isEmpty == true {
            hydrated.jellyfinItemId = task.remoteItemId
        }
        if hydrated.jellyfinServerId == nil || hydrated.jellyfinServerId?.isEmpty == true {
            hydrated.jellyfinServerId = task.serverId.uuidString
        }
        if hydrated.serverType == nil {
            hydrated.serverType = serverType
        }
        if hydrated.seriesId == nil || hydrated.seriesId?.isEmpty == true {
            hydrated.seriesId = task.seriesId
        }
        if hydrated.seasonId == nil || hydrated.seasonId?.isEmpty == true {
            hydrated.seasonId = task.seasonId
        }
        if hydrated.serverPath == nil || hydrated.serverPath?.isEmpty == true {
            hydrated.serverPath = task.remotePath
        }
        return hydrated
    }


    public func isDownloaded(serverId: UUID, remoteItemId: String) -> Bool {
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard let task = bestTask(serverId: serverId, remoteItemId: normalized) else { return false }
        guard task.status == .completed, let path = task.localFilePath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    public func taskStatus(serverId: UUID, remoteItemId: String) -> DownloadTaskStatus? {
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return bestTask(serverId: serverId, remoteItemId: normalized)?.status
    }

    public func taskStatus(serverId: UUID, remotePath: String) -> DownloadTaskStatus? {
        let normalized = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return bestTask(serverId: serverId, remotePath: normalized)?.status
    }

    public func localFileURL(serverId: UUID, remoteItemId: String) -> URL? {
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return validatedLocalFileURL(for: bestTask(serverId: serverId, remoteItemId: normalized))
    }

    public func localFileURL(serverId: UUID, remotePath: String) -> URL? {
        let normalized = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return validatedLocalFileURL(for: bestTask(serverId: serverId, remotePath: normalized))
    }

    public func aggregateState(serverId: UUID, remoteItemIds: [String]) -> DownloadAggregateState {
        let normalized = Array(Set(remoteItemIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !normalized.isEmpty else { return .notDownloaded }
        let matches = normalized.compactMap { bestTask(serverId: serverId, remoteItemId: $0) }
        return aggregateState(for: matches, totalExpected: normalized.count)
    }

    public func aggregateStateForRemotePaths(serverId: UUID, remotePaths: [String]) -> DownloadAggregateState {
        let normalized = Array(Set(remotePaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !normalized.isEmpty else { return .notDownloaded }
        let matches = normalized.compactMap { bestTask(serverId: serverId, remotePath: $0) }
        return aggregateState(for: matches, totalExpected: normalized.count)
    }

    @discardableResult
    public func enqueueMediaDownload(
        server: ServerConfig,
        remoteItemId: String,
        fileName: String,
        totalBytes: Int64?,
        displayTitle: String? = nil,
        groupTitle: String? = nil,
        collectionId: String? = nil,
        seriesId: String? = nil,
        seasonId: String? = nil
    ) -> Bool {
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let descriptor = DownloadJobDescriptor(
            kind: .singleMedia,
            sourceType: DownloadSourceType(serverType: server.type),
            title: groupTitle ?? displayTitle ?? fileName,
            groupTitle: groupTitle,
            collectionId: collectionId ?? normalized,
            seriesId: seriesId,
            seasonId: seasonId
        )
        let item = DownloadMediaBatchItem(
            remoteItemId: normalized,
            remotePath: mediaStreamDownloadPath(for: normalized),
            fileName: fileName,
            displayTitle: displayTitle ?? fileName,
            totalBytes: totalBytes,
            collectionId: collectionId ?? normalized,
            seriesId: seriesId,
            seasonId: seasonId,
            groupIndex: 0
        )
        return enqueueMediaBatch(server: server, items: [item], job: descriptor) > 0
    }

    private func mediaStreamDownloadPath(for remoteItemId: String) -> String {
        "/Videos/\(remoteItemId)/stream?Static=true&download=1"
    }

    @discardableResult
    public func enqueueMediaBatch(server: ServerConfig, items: [DownloadMediaBatchItem], job: DownloadJobDescriptor) -> Int {
        let createdAt = Date()
        let queuedItems = items.compactMap { item -> DownloadTaskItem? in
            let normalizedRemotePath = item.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRemotePath.isEmpty else { return nil }

            if let remoteItemId = item.remoteItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !remoteItemId.isEmpty,
               let status = taskStatus(serverId: server.id, remoteItemId: remoteItemId),
               status == .queued || status == .downloading || status == .paused || status == .completed {
                return nil
            }

            if let status = taskStatus(serverId: server.id, remotePath: normalizedRemotePath),
               status == .queued || status == .downloading || status == .paused || status == .completed {
                return nil
            }

            return DownloadTaskItem(
                id: UUID(),
                serverId: server.id,
                serverName: server.name,
                jobId: job.id,
                jobKind: job.kind,
                sourceType: job.sourceType,
                fileName: item.fileName,
                displayTitle: item.displayTitle,
                groupTitle: job.title,
                remotePath: normalizedRemotePath,
                remoteItemId: item.remoteItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
                collectionId: item.collectionId ?? job.collectionId,
                seriesId: item.seriesId ?? job.seriesId,
                seasonId: item.seasonId ?? job.seasonId,
                groupIndex: item.groupIndex,
                createdAt: createdAt,
                status: .queued,
                resumeCapability: DownloadResumeCapability(serverType: server.type),
                backgroundCapability: DownloadBackgroundCapability(serverType: server.type),
                progress: 0,
                bytesDownloaded: 0,
                bytesTotal: item.totalBytes ?? 0,
                speedBytesPerSec: 0,
                resumeData: nil,
                backgroundSessionTaskIdentifier: nil,
                stagingFilePath: nil,
                localFilePath: nil,
                errorMessage: nil
            )
        }

        guard !queuedItems.isEmpty else { return 0 }
        tasks.insert(contentsOf: queuedItems.reversed(), at: 0)
        persistTasks()
        drainQueue()
        return queuedItems.count
    }

    @discardableResult
    public func enqueueRemoteFileBatch(
        server: ServerConfig,
        items: [DownloadRemoteFileBatchItem],
        job: DownloadJobDescriptor
    ) -> Int {
        let createdAt = Date()
        let queuedItems = items.compactMap { item -> DownloadTaskItem? in
            let normalizedRemotePath = item.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRemotePath.isEmpty else { return nil }
            if let status = taskStatus(serverId: server.id, remotePath: normalizedRemotePath),
               status == .queued || status == .downloading || status == .paused || status == .completed {
                return nil
            }

            return DownloadTaskItem(
                id: UUID(),
                serverId: server.id,
                serverName: server.name,
                jobId: job.id,
                jobKind: job.kind,
                sourceType: job.sourceType,
                fileName: item.fileName,
                displayTitle: item.displayTitle,
                groupTitle: job.title,
                remotePath: normalizedRemotePath,
                remoteItemId: nil,
                collectionId: job.collectionId,
                seriesId: job.seriesId,
                seasonId: job.seasonId,
                groupIndex: item.groupIndex,
                createdAt: createdAt,
                status: .queued,
                resumeCapability: DownloadResumeCapability(serverType: server.type),
                backgroundCapability: DownloadBackgroundCapability(serverType: server.type),
                progress: 0,
                bytesDownloaded: 0,
                bytesTotal: item.totalBytes ?? 0,
                speedBytesPerSec: 0,
                resumeData: nil,
                backgroundSessionTaskIdentifier: nil,
                stagingFilePath: nil,
                localFilePath: nil,
                errorMessage: nil
            )
        }

        guard !queuedItems.isEmpty else { return 0 }
        tasks.insert(contentsOf: queuedItems.reversed(), at: 0)
        persistTasks()
        drainQueue()
        return queuedItems.count
    }

    private func taskMatches(_ task: DownloadTaskItem, remoteItemId: String, localFilePath: String?) -> Bool {
        if let explicitRemoteItemId = task.remoteItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           explicitRemoteItemId.caseInsensitiveCompare(remoteItemId) == .orderedSame {
            return true
        }
        let itemToken = "/Items/\(remoteItemId)"
        let streamToken = "/Videos/\(remoteItemId)/"
        let fallbackToken = "__\(remoteItemId)__"
        if task.remotePath.localizedCaseInsensitiveContains(itemToken) ||
            task.remotePath.localizedCaseInsensitiveContains(streamToken) ||
            task.remotePath.localizedCaseInsensitiveContains(remoteItemId) {
            return true
        }
        if task.fileName.localizedCaseInsensitiveContains(fallbackToken) ||
            task.fileName.localizedCaseInsensitiveContains(remoteItemId) {
            return true
        }
        guard let localFilePath, !localFilePath.isEmpty else { return false }
        let localName = URL(fileURLWithPath: localFilePath).lastPathComponent
        return localName.localizedCaseInsensitiveContains(fallbackToken) ||
            localName.localizedCaseInsensitiveContains(remoteItemId)
    }

    public func enqueueDownload(
        server: ServerConfig,
        remotePath: String,
        fileName: String,
        totalBytes: Int64?,
        displayTitle: String? = nil,
        groupTitle: String? = nil
    ) {
        let descriptor = DownloadJobDescriptor(
            kind: .fileBatch,
            sourceType: DownloadSourceType(serverType: server.type),
            title: groupTitle ?? displayTitle ?? fileName,
            groupTitle: groupTitle
        )
        _ = enqueueRemoteFileBatch(
            server: server,
            items: [
                DownloadRemoteFileBatchItem(
                    remotePath: remotePath,
                    fileName: fileName,
                    displayTitle: displayTitle ?? fileName,
                    totalBytes: totalBytes,
                    groupIndex: 0
                )
            ],
            job: descriptor
        )
    }

    public func pause(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        switch tasks[index].status {
        case .paused, .completed: return
        case .queued:
            let hasCheckpoint = tasks[index].resumeCapability == .resumable && (tasks[index].resumeData?.isEmpty == false)
            tasks[index].status = .paused
            tasks[index].speedBytesPerSec = 0
            tasks[index].backgroundSessionTaskIdentifier = nil
            tasks[index].errorMessage = hasCheckpoint ? "Paused. Tap resume to continue." : "Paused. Resuming will restart the download."
            persistTasks()
            drainQueue()
        case .downloading:
            terminationReasons[id] = .pause
            tasks[index].speedBytesPerSec = 0
            persistTasks()
            if tasks[index].backgroundCapability == .backgroundTransfer {
                backgroundDownloadManager.pauseDownload(id: id)
            } else if let activeHTTPDownload = activeHTTPDownloads[id] {
                activeHTTPDownload.pause()
            } else {
                runningTasks[id]?.cancel()
            }
        case .failed, .canceled: return
        }
    }

    public func resume(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard networkService.servers.first(where: { $0.id == tasks[index].serverId }) != nil else { return }
        let canResumeFromCheckpoint = tasks[index].resumeCapability == .resumable && (tasks[index].resumeData?.isEmpty == false)
        tasks[index].status = .queued
        tasks[index].speedBytesPerSec = 0
        tasks[index].errorMessage = nil
        tasks[index].localFilePath = nil
        tasks[index].backgroundSessionTaskIdentifier = nil
        if !canResumeFromCheckpoint {
            tasks[index].progress = 0
            tasks[index].bytesDownloaded = 0
            tasks[index].resumeData = nil
        }
        persistTasks()
        drainQueue()
    }

    public func cancel(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[index].isRunning {
            terminationReasons[id] = .cancel
            if tasks[index].backgroundCapability == .backgroundTransfer {
                backgroundDownloadManager.cancelDownload(id: id)
            } else if let activeHTTPDownload = activeHTTPDownloads[id] {
                activeHTTPDownload.cancel()
            } else {
                runningTasks[id]?.cancel()
            }
            return
        }
        tasks[index].status = .canceled
        tasks[index].progress = 0
        tasks[index].bytesDownloaded = 0
        tasks[index].speedBytesPerSec = 0
        tasks[index].resumeData = nil
        tasks[index].backgroundSessionTaskIdentifier = nil
        tasks[index].stagingFilePath = nil
        tasks[index].localFilePath = nil
        tasks[index].errorMessage = "Canceled by user"
        persistTasks()
        drainQueue()
    }

    public func retry(_ id: UUID) { resume(id) }

    public func pause(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && ($0.status == .queued || $0.status == .downloading) }.map(\.id)
        for id in ids { pause(id) }
    }

    public func resume(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && ($0.status == .paused || $0.status == .failed || $0.status == .canceled) }.map(\.id)
        for id in ids { resume(id) }
    }

    public func cancel(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && $0.isActive }.map(\.id)
        for id in ids { cancel(id) }
    }

    public func retry(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && ($0.status == .failed || $0.status == .canceled) }.map(\.id)
        for id in ids { retry(id) }
    }

    public func removeRecord(_ id: UUID, deleteLocalFile: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        if deleteLocalFile, let path = task.localFilePath {
            let fileURL = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: fileURL)
            Self.removeEmptyDownloadDirectories(
                afterRemoving: fileURL,
                rootDirectory: downloadsRootDirectory(fileManager: .default)
            )
        }
        if let stagingPath = task.stagingFilePath, !stagingPath.isEmpty { try? FileManager.default.removeItem(at: URL(fileURLWithPath: stagingPath)) }
        if task.backgroundCapability == .backgroundTransfer { backgroundDownloadManager.cancelDownload(id: id) }
        backgroundSpeedSamples[id] = nil
        activeHTTPDownloads[id]?.cancel()
        activeHTTPDownloads[id] = nil
        terminationReasons[id] = nil
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        tasks.remove(at: index)
        persistTasks()
        drainQueue()
    }

    public func removeJob(_ jobId: UUID, deleteLocalFile: Bool) {
        let ids = tasks.filter { $0.jobId == jobId }.map(\.id)
        for id in ids { removeRecord(id, deleteLocalFile: deleteLocalFile) }
    }

    public func removeRecords(createdOn day: Date, statuses: [DownloadTaskStatus], deleteLocalFiles: Bool) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids { removeRecord(id, deleteLocalFile: deleteLocalFiles) }
    }

    public func removeRecords(statuses: [DownloadTaskStatus], deleteLocalFiles: Bool) {
        let ids = tasks.compactMap { task -> UUID? in statuses.contains(task.status) ? task.id : nil }
        for id in ids { removeRecord(id, deleteLocalFile: deleteLocalFiles) }
    }

    public func clearDownloadedContent() { removeRecords(statuses: [.completed], deleteLocalFiles: true) }

    public func pauseRecords(createdOn day: Date, statuses: [DownloadTaskStatus]) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids { pause(id) }
    }

    public func resumeRecords(createdOn day: Date, statuses: [DownloadTaskStatus]) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids { resume(id) }
    }

    public func cancelRecords(createdOn day: Date, statuses: [DownloadTaskStatus]) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids { cancel(id) }
    }

    private func taskIDs(createdOn day: Date, statuses: [DownloadTaskStatus]) -> [UUID] {
        let calendar = Calendar.current
        return tasks.compactMap { task -> UUID? in
            guard statuses.contains(task.status), calendar.isDate(task.createdAt, inSameDayAs: day) else { return nil }
            return task.id
        }
    }

    private func uniqueExistingLocalFileURLs(for tasks: [DownloadTaskItem]) -> [URL] {
        let uniquePaths = Array(Set(tasks.compactMap { task -> String? in
            guard let path = task.localFilePath, !path.isEmpty else { return nil }
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: standardizedPath) else { return nil }
            return standardizedPath
        })).sorted()
        return uniquePaths.map { URL(fileURLWithPath: $0) }
    }

    public func updateTrackedLocalFileLocation(from oldURL: URL, to newURL: URL) {
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        let oldDirectoryPrefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        var didChange = false
        for index in tasks.indices {
            guard let path = tasks[index].localFilePath, !path.isEmpty else { continue }
            let trackedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            if trackedPath == oldPath {
                tasks[index].localFilePath = newPath
            } else if trackedPath.hasPrefix(oldDirectoryPrefix) {
                let suffix = String(trackedPath.dropFirst(oldDirectoryPrefix.count))
                tasks[index].localFilePath = newURL.appendingPathComponent(suffix).standardizedFileURL.path
            } else { continue }
            if tasks[index].status == .failed { tasks[index].status = .completed }
            tasks[index].errorMessage = nil
            didChange = true
        }
        if didChange { persistTasks() }
    }

    public func reconcileMissingLocalFiles() {
        var didChange = false
        for index in tasks.indices {
            guard let path = tasks[index].localFilePath, !path.isEmpty, !FileManager.default.fileExists(atPath: path) else { continue }
            if tasks[index].status == .completed {
                tasks[index].status = .failed
                tasks[index].errorMessage = Self.localizedMissingLocalFileMessage()
                didChange = true
            }
        }
        if didChange { persistTasks() }
    }

    private func checkpointAvailable(for task: DownloadTaskItem, resumeData: Data? = nil) -> Bool {
        guard task.resumeCapability == .resumable else { return false }
        return (resumeData ?? task.resumeData)?.isEmpty == false
    }

    private func pausedMessage(for _: DownloadResumeCapability, checkpointAvailable: Bool, interrupted: Bool) -> String {
        switch (interrupted, checkpointAvailable) {
        case (true, true): return "Download was interrupted. Tap resume to continue."
        case (true, false): return "Download was interrupted. Resume will restart the download."
        case (false, true): return "Paused. Tap resume to continue."
        case (false, false): return "Paused. Resuming will restart the download."
        }
    }

    private func applyPausedState(to task: inout DownloadTaskItem, resumeData: Data?, interrupted: Bool) {
        let hasCheckpoint = checkpointAvailable(for: task, resumeData: resumeData)
        task.status = .paused
        task.speedBytesPerSec = 0
        task.localFilePath = nil
        task.resumeData = hasCheckpoint ? resumeData : nil
        task.backgroundSessionTaskIdentifier = nil
        task.stagingFilePath = nil
        task.errorMessage = pausedMessage(for: task.resumeCapability, checkpointAvailable: hasCheckpoint, interrupted: interrupted)
        task.progress = hasCheckpoint ? (task.bytesTotal > 0 ? min(1.0, Double(task.bytesDownloaded) / Double(task.bytesTotal)) : task.progress) : 0
        if !hasCheckpoint { task.bytesDownloaded = 0 }
    }

    private func applyCanceledState(to task: inout DownloadTaskItem) {
        task.status = .canceled
        task.progress = 0
        task.bytesDownloaded = 0
        task.speedBytesPerSec = 0
        task.resumeData = nil
        task.backgroundSessionTaskIdentifier = nil
        task.stagingFilePath = nil
        task.localFilePath = nil
        task.errorMessage = "Canceled by user"
    }

    private func resumeData(from error: Error) -> Data? { (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data }

    private func configureLifecycleObservers() {
#if os(iOS)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBackgroundExecutionAssertion() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endBackgroundExecutionAssertion() }
        })
#endif
    }

#if os(iOS)
    private func refreshBackgroundExecutionAssertion() {
        if UIApplication.shared.applicationState == .background && !runningTasks.isEmpty { beginBackgroundExecutionAssertion() }
        else { endBackgroundExecutionAssertion() }
    }

    private func beginBackgroundExecutionAssertion() {
        guard backgroundTaskIdentifier == .invalid else { return }
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "GenPlayer.Downloads") { [weak self] in
            Task { @MainActor in self?.handleBackgroundExecutionExpiration() }
        }
    }

    private func endBackgroundExecutionAssertion() {
        guard backgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }

    private func handleBackgroundExecutionExpiration() {
        for id in runningTasks.keys {
            terminationReasons[id] = .pause
            if let activeHTTPDownload = activeHTTPDownloads[id] { activeHTTPDownload.pause() }
            else { runningTasks[id]?.cancel() }
        }
        endBackgroundExecutionAssertion()
    }
#else
    private func refreshBackgroundExecutionAssertion() {}
    private func endBackgroundExecutionAssertion() {}
#endif

    private func restoreBackgroundDownloads() {
        let candidateTasks = tasks.filter { $0.backgroundCapability == .backgroundTransfer }
#if os(tvOS)
        guard !candidateTasks.isEmpty else {
            backgroundDownloadManager.reconnectPersistedDownloads(persistedTasks: []) { [weak self] _ in
                Task { @MainActor in
                    self?.recoverInterruptedTasks(preservingActiveBackgroundTransfers: [])
                    self?.drainQueue()
                }
            }
            return
        }
#else
        guard !candidateTasks.isEmpty else {
            recoverInterruptedTasks(preservingActiveBackgroundTransfers: [])
            drainQueue()
            return
        }
#endif
        backgroundDownloadManager.reconnectPersistedDownloads(persistedTasks: candidateTasks) { [weak self] activeIDs in
            Task { @MainActor in
                self?.recoverInterruptedTasks(preservingActiveBackgroundTransfers: activeIDs)
                self?.drainQueue()
            }
        }
    }

    private func startDownload(for id: UUID, server: ServerConfig) {
        guard let taskItem = tasks.first(where: { $0.id == id }) else { return }
        if taskItem.backgroundCapability == .backgroundTransfer, let request = networkService.downloadRequest(server: server, at: taskItem.remotePath) {
            startBackgroundDownload(for: taskItem, request: request)
            return
        }
        guard runningTasks[id] == nil else { return }
        updateTask(id) {
            $0.status = .downloading
            $0.errorMessage = nil
            $0.speedBytesPerSec = 0
        }
        runningTasks[id] = Task {
            let currentTask = tasks.first(where: { $0.id == id }) ?? taskItem
            var lastObservedBytes = currentTask.bytesDownloaded
            var lastPublishedAt = Date(), lastSpeedSampleAt = Date()
            var sampledBytes: Int64 = 0, smoothedSpeedBytesPerSec = 0.0
            defer {
                activeHTTPDownloads[id] = nil
                terminationReasons[id] = nil
                runningTasks[id] = nil
                refreshBackgroundExecutionAssertion()
                DownloadCenterService.shared.drainQueue()
            }
            let progressHandler: (Int64, Int64) -> Void = { downloaded, total in
                Task { @MainActor in
                    guard self.tasks.first(where: { $0.id == id })?.status == .downloading else { return }
                    let now = Date(), delta = max(0, downloaded - lastObservedBytes)
                    lastObservedBytes = downloaded; sampledBytes += delta
                    let speedElapsed = now.timeIntervalSince(lastSpeedSampleAt)
                    if speedElapsed >= 0.9 || (total > 0 && downloaded >= total) {
                        let instant = Double(sampledBytes) / max(0.001, speedElapsed)
                        smoothedSpeedBytesPerSec = (smoothedSpeedBytesPerSec == 0) ? instant : (smoothedSpeedBytesPerSec * 0.65) + (instant * 0.35)
                        sampledBytes = 0; lastSpeedSampleAt = now
                    }
                    if now.timeIntervalSince(lastPublishedAt) >= 0.35 || (total > 0 && downloaded >= total) {
                        lastPublishedAt = now
                        DownloadCenterService.shared.updateTask(id, shouldPersist: false) {
                            $0.bytesDownloaded = downloaded
                            if total > 0 { $0.bytesTotal = total }
                            if $0.bytesTotal > 0 { $0.progress = min(1.0, Double(downloaded) / Double($0.bytesTotal)) }
                            $0.speedBytesPerSec = smoothedSpeedBytesPerSec
                        }
                    }
                }
            }
            do {
                let tempURL: URL
                if let request = networkService.downloadRequest(server: server, at: currentTask.remotePath) {
                    let managed = ManagedHTTPDownload(request: request, progressHandler: progressHandler)
                    activeHTTPDownloads[id] = managed
                    do {
                        tempURL = try await managed.start(resumeData: currentTask.resumeData)
                    } catch HTTPManagedDownloadInterruption.paused(let resumeData) {
                        updateTask(id) {
                            applyPausedState(to: &$0, resumeData: resumeData, interrupted: false)
                        }
                        return
                    }
                } else {
                    tempURL = try await networkService.downloadFile(server: server, at: currentTask.remotePath, progress: progressHandler)
                }
                if let reason = terminationReasons[id] {
                    try? FileManager.default.removeItem(at: tempURL)
                    updateTask(id) { reason == .pause ? applyPausedState(to: &$0, resumeData: nil, interrupted: false) : applyCanceledState(to: &$0) }
                    return
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: tempURL)
                    updateTask(id) { applyPausedState(to: &$0, resumeData: nil, interrupted: true) }
                    return
                }
                let completedBytes = try DownloadFileValidation.validateFile(at: tempURL)
                let destination = try self.persistDownloadedFile(from: tempURL, task: tasks.first(where: { $0.id == id }) ?? taskItem)
                updateTask(id) {
                    $0.status = .completed; $0.progress = 1; $0.localFilePath = destination.path
                    $0.resumeData = nil; $0.backgroundSessionTaskIdentifier = nil; $0.stagingFilePath = nil; $0.errorMessage = nil
                    $0.bytesTotal = completedBytes
                    $0.bytesDownloaded = completedBytes
                    $0.speedBytesPerSec = 0
                }
            } catch {
                if let reason = terminationReasons[id] {
                    updateTask(id) { reason == .pause ? applyPausedState(to: &$0, resumeData: resumeData(from: error), interrupted: false) : applyCanceledState(to: &$0) }
                } else if let resumeData = resumeData(from: error) {
                    updateTask(id) { applyPausedState(to: &$0, resumeData: resumeData, interrupted: true) }
                } else if Task.isCancelled {
                    updateTask(id) { applyPausedState(to: &$0, resumeData: nil, interrupted: true) }
                } else {
                    updateTask(id) {
                        $0.status = .failed
                        $0.errorMessage = error.localizedDescription
                        $0.speedBytesPerSec = 0
                        $0.resumeData = nil
                        $0.backgroundSessionTaskIdentifier = nil
                        $0.stagingFilePath = nil
                        $0.localFilePath = nil
                    }
                }
            }
        }
        refreshBackgroundExecutionAssertion()
    }

    private func startBackgroundDownload(for taskItem: DownloadTaskItem, request: URLRequest) {
        let sessionTaskIdentifier = backgroundDownloadManager.startDownload(id: taskItem.id, request: request, resumeData: taskItem.resumeData)
        backgroundSpeedSamples[taskItem.id] = DownloadSpeedSample(initialBytes: taskItem.bytesDownloaded)
        updateTask(taskItem.id) {
            $0.status = .downloading; $0.errorMessage = nil; $0.speedBytesPerSec = 0
            $0.backgroundSessionTaskIdentifier = sessionTaskIdentifier
        }
    }

    private func persistDownloadedFile(from tempURL: URL, task: DownloadTaskItem) throws -> URL {
        let fileManager = FileManager.default
        let expectedBytes: Int64?
        switch task.sourceType {
        case .smb, .ftp, .sftp, .nfs:
            expectedBytes = task.bytesTotal > 0 ? task.bytesTotal : nil
        default:
            expectedBytes = nil // HTTP artifacts were checked against the actual response.
        }
        do {
            try DownloadFileValidation.validateFile(at: tempURL, expectedBytes: expectedBytes)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
        let server = networkService.servers.first(where: { $0.id == task.serverId })
        let destinationDirectory = downloadDestinationDirectory(for: task, server: server, fileManager: fileManager)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = uniqueDownloadDestinationURL(
            in: destinationDirectory,
            preferredFileName: task.fileName,
            currentLocation: nil,
            fileManager: fileManager
        )
        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: tempURL, to: destinationURL)
            try? fileManager.removeItem(at: tempURL)
        }
        return destinationURL
    }

    // Walk only the deleted file's ancestors; never scan or remove Downloads itself.
    static func removeEmptyDownloadDirectories(afterRemoving fileURL: URL, rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL
        var directory = fileURL.standardizedFileURL.deletingLastPathComponent()
        guard directory.pathComponents.count > root.pathComponents.count,
              directory.pathComponents.starts(with: root.pathComponents) else { return }

        // Refuse symbolic-link ancestors so cleanup cannot follow a redirected directory.
        var ancestor = directory
        while true {
            guard let values = try? ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return }
            if ancestor.path == root.path { break }
            ancestor = ancestor.deletingLastPathComponent()
        }

        while directory.pathComponents.count > root.pathComponents.count {
            // rmdir atomically refuses nonempty directories, including hidden files and
            // files that another download wrote after cleanup started. Never recurse.
            let removed = directory.withUnsafeFileSystemRepresentation { path in
                guard let path = path else { return false }
                return Darwin.rmdir(path) == 0
            }
            guard removed else { return }
            directory = directory.deletingLastPathComponent()
        }
    }

    private func downloadsRootDirectory(fileManager: FileManager) -> URL {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func downloadDestinationDirectory(
        for task: DownloadTaskItem,
        server: ServerConfig?,
        fileManager: FileManager
    ) -> URL {
        let serverRoot = serverDownloadDirectory(for: task, server: server, fileManager: fileManager)
        let storageComponents = downloadStorageSubdirectories(for: task)
        return storageComponents.reduce(serverRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private func serverDownloadDirectory(
        for task: DownloadTaskItem,
        server: ServerConfig?,
        fileManager: FileManager
    ) -> URL {
        let serverTypeName = server?.type.rawValue.capitalized ?? task.sourceType.rawValue.capitalized
        let serverName = server?.name ?? task.serverName
        let typeDirectory = sanitizedPathComponent(serverTypeName, fallback: "Servers")
        let serverDirectory = sanitizedPathComponent(serverName, fallback: task.serverId.uuidString)

        return downloadsRootDirectory(fileManager: fileManager)
            .appendingPathComponent(typeDirectory, isDirectory: true)
            .appendingPathComponent(serverDirectory, isDirectory: true)
    }

    private func downloadStorageSubdirectories(for task: DownloadTaskItem) -> [String] {
        switch task.sourceType {
        case .jellyfin, .emby, .plex:
            return mediaServerStorageSubdirectories(for: task)
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs:
            return remoteFileStorageSubdirectories(for: task)
        case .localImport:
            return ["Local Imports"]
        case .unknown:
            return ["Others"]
        }
    }

    private func mediaServerStorageSubdirectories(for task: DownloadTaskItem) -> [String] {
        guard let seriesFolder = inferredSeriesFolderName(for: task) else {
            return ["Movies"]
        }

        var components = ["TV Shows", seriesFolder]
        if let seasonFolder = inferredSeasonFolderName(for: task) {
            components.append(seasonFolder)
        }
        return components
    }

    private func remoteFileStorageSubdirectories(for task: DownloadTaskItem) -> [String] {
        ["Files"] + remoteParentDirectoryComponents(for: task)
    }

    private func remoteParentDirectoryComponents(for task: DownloadTaskItem) -> [String] {
        let normalizedPath = task.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return [] }

        let pathString: String
        if let absoluteURL = URL(string: normalizedPath), absoluteURL.scheme != nil {
            pathString = absoluteURL.path
        } else {
            pathString = normalizedPath
        }

        let rawComponents = pathString
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)

        guard rawComponents.count > 1 else { return [] }
        return rawComponents.dropLast().map {
            sanitizedPathComponent($0, fallback: "Folder")
        }
    }

    private func inferredSeriesFolderName(for task: DownloadTaskItem) -> String? {
        guard let episodeTitlePrefix = episodeTitlePrefix(from: task.fileName)
            ?? episodeTitlePrefix(from: task.displayTitle)
            ?? episodeTitlePrefix(from: task.groupTitle) else {
            return nil
        }

        if task.seriesId != nil || task.seasonId != nil || looksLikeEpisodeTitle(task.fileName) {
            return sanitizedPathComponent(episodeTitlePrefix, fallback: "TV Show")
        }
        return nil
    }

    private func inferredSeasonFolderName(for task: DownloadTaskItem) -> String? {
        if let seasonNumber = seasonNumber(from: task.fileName) ?? seasonNumber(from: task.displayTitle) {
            return String(format: "Season %02d", seasonNumber)
        }
        return nil
    }

    private func episodeTitlePrefix(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let stem = URL(fileURLWithPath: rawValue).deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: #" - S\d{1,2}E\d{1,3}\b"#, options: .regularExpression) else {
            return nil
        }

        let prefix = String(stem[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix
    }

    private func looksLikeEpisodeTitle(_ rawValue: String?) -> Bool {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return false
        }

        let stem = URL(fileURLWithPath: rawValue).deletingPathExtension().lastPathComponent
        return stem.range(of: #"\bS\d{1,2}E\d{1,3}\b"#, options: .regularExpression) != nil
    }

    private func seasonNumber(from rawValue: String?) -> Int? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let range = rawValue.range(of: #"\bS(\d{1,2})E\d{1,3}\b"#, options: .regularExpression) else {
            return nil
        }

        let match = String(rawValue[range])
        guard let seasonRange = match.range(of: #"S(\d{1,2})"#, options: .regularExpression) else {
            return nil
        }

        return Int(match[seasonRange].dropFirst())
    }

    private func uniqueDownloadDestinationURL(
        in directory: URL,
        preferredFileName: String,
        currentLocation: URL?,
        fileManager: FileManager
    ) -> URL {
        let sanitizedName = sanitizedDownloadFileName(preferredFileName)
        let sourceURL = URL(fileURLWithPath: sanitizedName)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        let normalizedCurrentPath = currentLocation?.standardizedFileURL.path

        var destinationURL = directory.appendingPathComponent(sanitizedName)
        var counter = 1

        while fileManager.fileExists(atPath: destinationURL.path) &&
                destinationURL.standardizedFileURL.path != normalizedCurrentPath {
            let nextName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            destinationURL = directory.appendingPathComponent(nextName)
            counter += 1
        }

        return destinationURL
    }

    private func sanitizedDownloadFileName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return sanitized.isEmpty ? UUID().uuidString : sanitized
    }

    private func sanitizedPathComponent(_ rawValue: String, fallback: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let replaced = rawValue.components(separatedBy: invalidCharacters).joined(separator: "_")
        let normalizedWhitespace = replaced.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = normalizedWhitespace.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func updateTask(_ id: UUID, shouldPersist: Bool = true, mutate: (inout DownloadTaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        if shouldPersist {
            persistTasks()
        }
    }

    private func loadPersistedTasks() {
        guard let data = try? Data(contentsOf: persistenceURL), let decoded = try? JSONDecoder().decode([DownloadTaskItem].self, from: data) else { return }
        tasks = normalizePersistedTasks(decoded).sorted { $0.createdAt > $1.createdAt }
        persistTasks()
    }

    private func recoverInterruptedTasks(preservingActiveBackgroundTransfers activeBackgroundTransfers: Set<UUID>) {
        var didChange = false
        for index in tasks.indices {
            tasks[index].speedBytesPerSec = 0
            if activeBackgroundTransfers.contains(tasks[index].id) { tasks[index].status = .downloading; tasks[index].errorMessage = nil; didChange = true; continue }
            switch tasks[index].status {
            case .queued, .downloading: applyPausedState(to: &tasks[index], resumeData: tasks[index].resumeData, interrupted: true); didChange = true
            case .paused: if tasks[index].errorMessage?.isEmpty != false { tasks[index].errorMessage = pausedMessage(for: tasks[index].resumeCapability, checkpointAvailable: checkpointAvailable(for: tasks[index]), interrupted: false); didChange = true }
            default: break
            }
        }
        if didChange { persistTasks() }
    }

    private func persistTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        let targetURL = persistenceURL
        persistenceQueue.async {
            try? data.write(to: targetURL, options: .atomic)
        }
    }

    private func normalizePersistedTasks(_ decoded: [DownloadTaskItem]) -> [DownloadTaskItem] {
        decoded.map { task in
            var n = task
            if n.displayTitle.isEmpty { n.displayTitle = n.fileName }
            if Self.isMissingLocalFileMessage(n.errorMessage) {
                n.errorMessage = Self.localizedMissingLocalFileMessage()
            }
            if n.sourceType == .unknown, let st = networkService.servers.first(where: { $0.id == n.serverId })?.type { n.sourceType = DownloadSourceType(serverType: st) }
            if n.jobKind == .singleMedia && n.groupTitle == nil { n.groupTitle = n.displayTitle }
            if n.resumeCapability == .unknown { n.resumeCapability = DownloadResumeCapability(sourceType: n.sourceType) }
#if os(tvOS)
            n.backgroundCapability = DownloadBackgroundCapability(sourceType: n.sourceType)
#else
            if n.backgroundCapability == .unknown { n.backgroundCapability = DownloadBackgroundCapability(sourceType: n.sourceType) }
#endif
            if n.status != .queued && n.status != .downloading { n.backgroundSessionTaskIdentifier = nil }
            if n.status == .completed { n.progress = 1; n.resumeData = nil; n.backgroundSessionTaskIdentifier = nil; n.stagingFilePath = nil }
            else if n.status == .canceled { n.resumeData = nil; n.backgroundSessionTaskIdentifier = nil; n.stagingFilePath = nil }
            else if n.bytesTotal > 0 { n.progress = min(1.0, Double(n.bytesDownloaded) / Double(n.bytesTotal)) }
            if n.status == .failed,
               Self.isMissingLocalFileMessage(n.errorMessage),
               let path = n.localFilePath,
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                n.status = .completed
                n.progress = 1
                n.errorMessage = nil
                n.resumeData = nil
                n.backgroundSessionTaskIdentifier = nil
                n.stagingFilePath = nil
            }
            return n
        }
    }

    private static func localizedMissingLocalFileMessage() -> String {
        NSLocalizedString(missingLocalFileMessageKey, comment: "")
    }

    private static func isMissingLocalFileMessage(_ message: String?) -> Bool {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return false
        }
        return message == missingLocalFileMessageKey || message == localizedMissingLocalFileMessage()
    }

    private func bestTask(serverId: UUID, remoteItemId: String) -> DownloadTaskItem? {
        bestTask { $0.serverId == serverId && taskMatches($0, remoteItemId: remoteItemId, localFilePath: $0.localFilePath) }
    }

    private func bestTask(serverId: UUID, remotePath: String) -> DownloadTaskItem? {
        bestTask { $0.serverId == serverId && $0.remotePath == remotePath }
    }

    private func bestTask(where predicate: (DownloadTaskItem) -> Bool) -> DownloadTaskItem? {
        tasks.filter(predicate).sorted(by: isPreferredTask(_:over:)).first
    }

    private func validatedLocalFileURL(for task: DownloadTaskItem?) -> URL? {
        guard let task, task.status == .completed, let path = task.localFilePath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func isPreferredTask(_ lhs: DownloadTaskItem, over rhs: DownloadTaskItem) -> Bool {
        let lr = statusRank(lhs.status), rr = statusRank(rhs.status)
        return lr == rr ? lhs.createdAt > rhs.createdAt : lr < rr
    }

    private func statusRank(_ status: DownloadTaskStatus) -> Int {
        switch status { case .downloading: return 0; case .queued: return 1; case .paused: return 2; case .completed: return 3; case .failed: return 4; case .canceled: return 5 }
    }

    private func aggregateState(for matches: [DownloadTaskItem], totalExpected: Int) -> DownloadAggregateState {
        guard !matches.isEmpty else { return .notDownloaded }
        let completed = matches.filter { $0.status == .completed }.count
        if completed == totalExpected { return .downloaded }
        if matches.contains(where: { $0.status == .downloading }) { return .downloading(completed: completed, total: totalExpected) }
        if matches.contains(where: { $0.status == .queued || $0.status == .paused }) { return .queued(completed: completed, total: totalExpected) }
        return completed > 0 ? .partiallyDownloaded(completed: completed, total: totalExpected) : .failed(completed: completed, total: totalExpected)
    }
}

extension DownloadCenterService: BackgroundDownloadSessionManagerDelegate {
    public func backgroundDownloadSessionManager(_ manager: BackgroundDownloadSessionManager, didReconnectDownload id: UUID, sessionTaskIdentifier: Int, bytesDownloaded: Int64, totalBytes: Int64) {
        guard tasks.contains(where: { $0.id == id }) else { manager.cancelDownload(id: id); return }
        backgroundSpeedSamples[id] = DownloadSpeedSample(initialBytes: bytesDownloaded)
        updateTask(id) {
            $0.status = .downloading; $0.backgroundSessionTaskIdentifier = sessionTaskIdentifier
            $0.bytesDownloaded = max($0.bytesDownloaded, bytesDownloaded)
            if totalBytes > 0 { $0.bytesTotal = max($0.bytesTotal, totalBytes) }
            if $0.bytesTotal > 0 { $0.progress = min(1.0, Double($0.bytesDownloaded) / Double($0.bytesTotal)) }
        }
    }

    public func backgroundDownloadSessionManager(_ manager: BackgroundDownloadSessionManager, didUpdateDownload id: UUID, bytesDownloaded: Int64, totalBytes: Int64) {
        guard let task = tasks.first(where: { $0.id == id }) else { manager.cancelDownload(id: id); return }
        guard task.status == .queued || task.status == .downloading else { return }
        var sample = backgroundSpeedSamples[id] ?? DownloadSpeedSample(initialBytes: max(task.bytesDownloaded, bytesDownloaded))
        let now = Date(), delta = max(0, bytesDownloaded - sample.lastObservedBytes)
        sample.lastObservedBytes = bytesDownloaded; sample.sampledBytes += delta
        let speedElapsed = now.timeIntervalSince(sample.lastSpeedSampleAt)
        if speedElapsed >= 0.9 || (totalBytes > 0 && bytesDownloaded >= totalBytes) {
            let instant = Double(sample.sampledBytes) / max(0.001, speedElapsed)
            sample.smoothedSpeedBytesPerSec = (sample.smoothedSpeedBytesPerSec == 0) ? instant : (sample.smoothedSpeedBytesPerSec * 0.65) + (instant * 0.35)
            sample.sampledBytes = 0; sample.lastSpeedSampleAt = now
        }
        if now.timeIntervalSince(sample.lastPublishedAt) >= 0.35 || (totalBytes > 0 && bytesDownloaded >= totalBytes) {
            sample.lastPublishedAt = now
            updateTask(id, shouldPersist: false) {
                $0.status = .downloading; $0.bytesDownloaded = bytesDownloaded
                if totalBytes > 0 { $0.bytesTotal = totalBytes }
                if $0.bytesTotal > 0 { $0.progress = min(1.0, Double(bytesDownloaded) / Double($0.bytesTotal)) }
                $0.speedBytesPerSec = sample.smoothedSpeedBytesPerSec
            }
        }
        backgroundSpeedSamples[id] = sample
    }

    public func backgroundDownloadSessionManager(_ manager: BackgroundDownloadSessionManager, didFinishDownloading id: UUID, to stagingURL: URL) {
        guard let task = tasks.first(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: stagingURL); manager.cancelDownload(id: id); return }
        guard (task.status == .queued || task.status == .downloading), terminationReasons[id] == nil else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }
        updateTask(id) { $0.stagingFilePath = stagingURL.path }
        do {
            let completedBytes = try DownloadFileValidation.validateFile(at: stagingURL)
            let destination = try persistDownloadedFile(from: stagingURL, task: task)
            updateTask(id) {
                $0.status = .completed; $0.progress = 1; $0.localFilePath = destination.path
                $0.bytesTotal = completedBytes
                $0.bytesDownloaded = completedBytes
                $0.speedBytesPerSec = 0
            }
        } catch {
            removeStagingFile(for: id)
            updateTask(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                $0.speedBytesPerSec = 0
                $0.resumeData = nil
                $0.backgroundSessionTaskIdentifier = nil
                $0.stagingFilePath = nil
                $0.localFilePath = nil
            }
        }
        drainQueue()
    }

    public func backgroundDownloadSessionManager(_ manager: BackgroundDownloadSessionManager, didCompleteDownload id: UUID, error: Error?, resumeData: Data?) {
        defer {
            backgroundSpeedSamples[id] = nil
            terminationReasons[id] = nil
            drainQueue()
        }
        guard let task = tasks.first(where: { $0.id == id }) else { removeStagingFile(for: id); return }
        if task.status == .completed, error == nil { updateTask(id) { $0.backgroundSessionTaskIdentifier = nil; $0.resumeData = nil; $0.stagingFilePath = nil }; return }
        if let reason = terminationReasons[id] {
            removeStagingFile(for: id)
            updateTask(id) { reason == .pause ? applyPausedState(to: &$0, resumeData: resumeData, interrupted: false) : applyCanceledState(to: &$0) }
            return
        }
        removeStagingFile(for: id)
        if let rd = resumeData { updateTask(id) { applyPausedState(to: &$0, resumeData: rd, interrupted: true) } }
        else if (error as NSError?)?.code == NSURLErrorCancelled { updateTask(id) { applyPausedState(to: &$0, resumeData: nil, interrupted: true) } }
        else if let error {
            updateTask(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                $0.speedBytesPerSec = 0
                $0.resumeData = nil
                $0.backgroundSessionTaskIdentifier = nil
                $0.stagingFilePath = nil
                $0.localFilePath = nil
            }
        }
    }

    private func removeStagingFile(for id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), let path = task.stagingFilePath, !path.isEmpty else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}

// Internal HTTP download helper moved from NetworkService
private final class ManagedHTTPDownload: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let request: URLRequest
    private let progressHandler: ((Int64, Int64) -> Void)?
    private let destinationURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var didFinish = false
    private var pauseRequested = false
    private lazy var session: URLSession = { URLSession(configuration: .default, delegate: self, delegateQueue: nil) }()

    init(request: URLRequest, progressHandler: ((Int64, Int64) -> Void)?) {
        self.request = request
        self.progressHandler = progressHandler
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let name = request.url?.lastPathComponent.isEmpty == false ? request.url!.lastPathComponent : UUID().uuidString
        self.destinationURL = temp.appendingPathComponent(name.contains(".") ? name : "\(name).bin")
    }

    func start(resumeData: Data?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.didFinish = false
            self.pauseRequested = false
            lock.unlock()
            let t = (resumeData != nil && !resumeData!.isEmpty) ? session.downloadTask(withResumeData: resumeData!) : session.downloadTask(with: request)
            task = t; t.resume()
        }
    }

    func pause() {
        lock.lock()
        if didFinish { lock.unlock(); return }
        pauseRequested = true
        let t = task
        lock.unlock()
        t?.cancel(byProducingResumeData: { [weak self] rd in self?.finish(with: .failure(HTTPManagedDownloadInterruption.paused(rd))) })
    }

    func cancel() {
        lock.lock()
        if didFinish { lock.unlock(); return }
        pauseRequested = false
        let t = task
        lock.unlock()
        t?.cancel()
    }

    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish, let c = continuation else { lock.unlock(); return }
        didFinish = true; continuation = nil
        lock.unlock()
        c.resume(with: result)
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try DownloadFileValidation.validateHTTP(response: downloadTask.response, fileURL: location)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) { try FileManager.default.removeItem(at: destinationURL) }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            finish(with: .success(destinationURL))
        } catch { finish(with: .failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if pauseRequested, (error as NSError).code == NSURLErrorCancelled { return }
        finish(with: .failure(error))
    }
}

private enum HTTPManagedDownloadInterruption: Error {
    case paused(Data?)
}

// Shared helper from NetworkService if needed
private final class HTTPDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let progressHandler: ((Int64, Int64) -> Void)?
    private let destinationURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var didFinish = false
    var task: URLSessionDownloadTask?

    init(destinationURL: URL, progressHandler: ((Int64, Int64) -> Void)?) {
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
    }

    func installContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func cancel() { task?.cancel() }

    private func resumeOnce(with result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish, let continuation else { lock.unlock(); return }
        didFinish = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try DownloadFileValidation.validateHTTP(response: downloadTask.response, fileURL: location)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) { try FileManager.default.removeItem(at: destinationURL) }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            resumeOnce(with: .success(destinationURL))
        } catch { resumeOnce(with: .failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resumeOnce(with: .failure(error)) }
    }
}
