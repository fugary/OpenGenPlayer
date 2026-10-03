import Foundation

public final class ICloudServerListSyncService {
    public static let shared = ICloudServerListSyncService()

    private let store = NSUbiquitousKeyValueStore.default
    private let payloadKey = "icloud_server_list_payload_v1"

    private init() {}

    public func pushServerList(
        _ servers: [ServerConfig],
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        privacySpace: PrivacySpaceSnapshot? = PrivacySpaceService.shared.currentSnapshot
    ) {
        let payload = ICloudServerListPayload(
            updatedAt: updatedAt,
            servers: servers,
            privacySpace: privacySpace
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        store.set(data, forKey: payloadKey)
        store.synchronize()
    }

    public func pullPayload() -> ICloudServerListPayload? {
        store.synchronize()
        guard let data = store.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(ICloudServerListPayload.self, from: data) else {
            return nil
        }
        return payload
    }
}

public enum DownloadTaskStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case canceled
}

public enum DownloadResumeCapability: String, Codable {
    case resumable
    case restartOnly
    case unknown

    public init(serverType: ServerConfig.ServerType) {
        switch serverType {
        case .jellyfin, .emby, .plex, .webdav, .onedrive, .googledrive:
            self = .resumable
        case .smb, .alist, .pan115, .ftp, .sftp, .nfs:
            self = .restartOnly
        case .iptv, .vod:
            self = .unknown
        }
    }

    public init(sourceType: DownloadSourceType) {
        switch sourceType {
        case .jellyfin, .emby, .plex, .webdav, .onedrive, .googledrive:
            self = .resumable
        case .smb, .alist, .pan115, .ftp, .sftp, .nfs:
            self = .restartOnly
        case .localImport, .unknown:
            self = .unknown
        }
    }
}

public enum DownloadBackgroundCapability: String, Codable {
    case backgroundTransfer
    case foregroundOnly
    case unknown

    public init(serverType: ServerConfig.ServerType) {
#if os(tvOS)
        switch serverType {
        case .jellyfin, .emby, .plex, .webdav, .alist, .pan115, .onedrive, .googledrive, .smb, .ftp, .sftp, .nfs, .iptv, .vod:
            self = .foregroundOnly
        }
#else
        switch serverType {
        case .jellyfin, .emby, .plex, .webdav, .onedrive, .googledrive:
            self = .backgroundTransfer
        case .smb, .alist, .pan115, .ftp, .sftp, .nfs:
            self = .foregroundOnly
        case .iptv, .vod:
            self = .unknown
        }
#endif
    }

    public init(sourceType: DownloadSourceType) {
#if os(tvOS)
        switch sourceType {
        case .jellyfin, .emby, .plex, .webdav, .alist, .pan115, .onedrive, .googledrive, .smb, .ftp, .sftp, .nfs:
            self = .foregroundOnly
        case .localImport, .unknown:
            self = .unknown
        }
#else
        switch sourceType {
        case .jellyfin, .emby, .plex, .webdav, .onedrive, .googledrive:
            self = .backgroundTransfer
        case .smb, .alist, .pan115, .ftp, .sftp, .nfs:
            self = .foregroundOnly
        case .localImport, .unknown:
            self = .unknown
        }
#endif
    }
}

public enum DownloadSourceType: String, Codable {
    case jellyfin
    case emby
    case plex
    case smb
    case webdav
    case ftp
    case sftp
    case nfs
    case localImport
    case alist
    case pan115 = "115"
    case onedrive
    case googledrive
    case unknown
    
    public init(serverType: ServerConfig.ServerType) {
        switch serverType {
        case .jellyfin: self = .jellyfin
        case .emby: self = .emby
        case .plex: self = .plex
        case .smb: self = .smb
        case .webdav: self = .webdav
        case .ftp: self = .ftp
        case .sftp: self = .sftp
        case .nfs: self = .nfs
        case .alist: self = .alist
        case .pan115: self = .pan115
        case .onedrive: self = .onedrive
        case .googledrive: self = .googledrive
        case .iptv, .vod: self = .unknown
        }
    }

    public var serverType: ServerConfig.ServerType? {
        switch self {
        case .jellyfin: return .jellyfin
        case .emby: return .emby
        case .plex: return .plex
        case .smb: return .smb
        case .webdav: return .webdav
        case .ftp: return .ftp
        case .sftp: return .sftp
        case .nfs: return .nfs
        case .alist: return .alist
        case .pan115: return .pan115
        case .onedrive: return .onedrive
        case .googledrive: return .googledrive
        case .localImport, .unknown: return nil
        }
    }
}

public enum DownloadJobKind: String, Codable {
    case singleMedia
    case seasonPack
    case fileBatch
}

public enum DownloadAggregateState: Equatable {
    case notDownloaded
    case queued(completed: Int, total: Int)
    case downloading(completed: Int, total: Int)
    case partiallyDownloaded(completed: Int, total: Int)
    case downloaded
    case failed(completed: Int, total: Int)
}

public struct DownloadJobDescriptor {
    public let id: UUID
    public let kind: DownloadJobKind
    public let sourceType: DownloadSourceType
    public let title: String
    public let groupTitle: String?
    public let collectionId: String?
    public let seriesId: String?
    public let seasonId: String?

    public init(
        id: UUID = UUID(),
        kind: DownloadJobKind,
        sourceType: DownloadSourceType,
        title: String,
        groupTitle: String? = nil,
        collectionId: String? = nil,
        seriesId: String? = nil,
        seasonId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sourceType = sourceType
        self.title = title
        self.groupTitle = groupTitle
        self.collectionId = collectionId
        self.seriesId = seriesId
        self.seasonId = seasonId
    }
}

public struct DownloadMediaBatchItem {
    public let remoteItemId: String?
    public let remotePath: String
    public let fileName: String
    public let displayTitle: String
    public let totalBytes: Int64?
    public let collectionId: String?
    public let seriesId: String?
    public let seasonId: String?
    public let groupIndex: Int
    
    public init(remoteItemId: String?, remotePath: String, fileName: String, displayTitle: String, totalBytes: Int64?, collectionId: String?, seriesId: String?, seasonId: String?, groupIndex: Int) {
        self.remoteItemId = remoteItemId
        self.remotePath = remotePath
        self.fileName = fileName
        self.displayTitle = displayTitle
        self.totalBytes = totalBytes
        self.collectionId = collectionId
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.groupIndex = groupIndex
    }
}

public struct DownloadRemoteFileBatchItem {
    public let remotePath: String
    public let fileName: String
    public let displayTitle: String
    public let totalBytes: Int64?
    public let groupIndex: Int
    
    public init(remotePath: String, fileName: String, displayTitle: String, totalBytes: Int64?, groupIndex: Int) {
        self.remotePath = remotePath
        self.fileName = fileName
        self.displayTitle = displayTitle
        self.totalBytes = totalBytes
        self.groupIndex = groupIndex
    }
}

public struct DownloadTaskItem: Identifiable, Codable {
    public let id: UUID
    public let serverId: UUID
    public let serverName: String
    public var jobId: UUID
    public var jobKind: DownloadJobKind
    public var sourceType: DownloadSourceType
    public let fileName: String
    public var displayTitle: String
    public var groupTitle: String?
    public let remotePath: String
    public var remoteItemId: String?
    public var collectionId: String?
    public var seriesId: String?
    public var seasonId: String?
    public var groupIndex: Int
    public let createdAt: Date

    public var status: DownloadTaskStatus
    public var resumeCapability: DownloadResumeCapability
    public var backgroundCapability: DownloadBackgroundCapability
    public var progress: Double
    public var bytesDownloaded: Int64
    public var bytesTotal: Int64
    public var speedBytesPerSec: Double
    public var resumeData: Data?
    public var backgroundSessionTaskIdentifier: Int?
    public var stagingFilePath: String?
    public var localFilePath: String?
    public var errorMessage: String?

    public var isActive: Bool { status == .queued || status == .downloading || status == .paused }
    public var isRunning: Bool { status == .queued || status == .downloading }
    
    public init(id: UUID, serverId: UUID, serverName: String, jobId: UUID, jobKind: DownloadJobKind, sourceType: DownloadSourceType, fileName: String, displayTitle: String, groupTitle: String? = nil, remotePath: String, remoteItemId: String? = nil, collectionId: String? = nil, seriesId: String? = nil, seasonId: String? = nil, groupIndex: Int, createdAt: Date, status: DownloadTaskStatus, resumeCapability: DownloadResumeCapability, backgroundCapability: DownloadBackgroundCapability, progress: Double, bytesDownloaded: Int64, bytesTotal: Int64, speedBytesPerSec: Double, resumeData: Data? = nil, backgroundSessionTaskIdentifier: Int? = nil, stagingFilePath: String? = nil, localFilePath: String? = nil, errorMessage: String? = nil) {
        self.id = id
        self.serverId = serverId
        self.serverName = serverName
        self.jobId = jobId
        self.jobKind = jobKind
        self.sourceType = sourceType
        self.fileName = fileName
        self.displayTitle = displayTitle
        self.groupTitle = groupTitle
        self.remotePath = remotePath
        self.remoteItemId = remoteItemId
        self.collectionId = collectionId
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.groupIndex = groupIndex
        self.createdAt = createdAt
        self.status = status
        self.resumeCapability = resumeCapability
        self.backgroundCapability = backgroundCapability
        self.progress = progress
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
        self.speedBytesPerSec = speedBytesPerSec
        self.resumeData = resumeData
        self.backgroundSessionTaskIdentifier = backgroundSessionTaskIdentifier
        self.stagingFilePath = stagingFilePath
        self.localFilePath = localFilePath
        self.errorMessage = errorMessage
    }

    public enum CodingKeys: String, CodingKey {
        case id, serverId, serverName, jobId, jobKind, sourceType
        case fileName, displayTitle, groupTitle, remotePath, remoteItemId
        case collectionId, seriesId, seasonId, groupIndex, createdAt
        case status, resumeCapability, backgroundCapability, progress, bytesDownloaded, bytesTotal, speedBytesPerSec
        case resumeData, backgroundSessionTaskIdentifier, stagingFilePath, localFilePath, errorMessage
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(jobId, forKey: .jobId)
        try container.encode(jobKind, forKey: .jobKind)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(displayTitle, forKey: .displayTitle)
        try container.encodeIfPresent(groupTitle, forKey: .groupTitle)
        try container.encode(remotePath, forKey: .remotePath)
        try container.encodeIfPresent(remoteItemId, forKey: .remoteItemId)
        try container.encodeIfPresent(collectionId, forKey: .collectionId)
        try container.encodeIfPresent(seriesId, forKey: .seriesId)
        try container.encodeIfPresent(seasonId, forKey: .seasonId)
        try container.encode(groupIndex, forKey: .groupIndex)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(status, forKey: .status)
        try container.encode(resumeCapability, forKey: .resumeCapability)
        try container.encode(backgroundCapability, forKey: .backgroundCapability)
        try container.encode(progress, forKey: .progress)
        try container.encode(bytesDownloaded, forKey: .bytesDownloaded)
        try container.encode(bytesTotal, forKey: .bytesTotal)
        try container.encode(speedBytesPerSec, forKey: .speedBytesPerSec)
        try container.encodeIfPresent(resumeData, forKey: .resumeData)
        try container.encodeIfPresent(backgroundSessionTaskIdentifier, forKey: .backgroundSessionTaskIdentifier)
        try container.encodeIfPresent(stagingFilePath, forKey: .stagingFilePath)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)

        if let localFilePath {
            try container.encode(Self.relativeLocalPath(forRawPath: localFilePath) ?? localFilePath, forKey: .localFilePath)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serverId = try container.decode(UUID.self, forKey: .serverId)
        serverName = try container.decode(String.self, forKey: .serverName)
        jobId = try container.decodeIfPresent(UUID.self, forKey: .jobId) ?? id
        jobKind = try container.decodeIfPresent(DownloadJobKind.self, forKey: .jobKind) ?? .singleMedia
        sourceType = try container.decodeIfPresent(DownloadSourceType.self, forKey: .sourceType) ?? .unknown
        fileName = try container.decode(String.self, forKey: .fileName)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle) ?? fileName
        groupTitle = try container.decodeIfPresent(String.self, forKey: .groupTitle)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        remoteItemId = try container.decodeIfPresent(String.self, forKey: .remoteItemId)
        collectionId = try container.decodeIfPresent(String.self, forKey: .collectionId)
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
        seasonId = try container.decodeIfPresent(String.self, forKey: .seasonId)
        groupIndex = try container.decodeIfPresent(Int.self, forKey: .groupIndex) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(DownloadTaskStatus.self, forKey: .status)
        resumeCapability = try container.decodeIfPresent(DownloadResumeCapability.self, forKey: .resumeCapability) ?? DownloadResumeCapability(sourceType: sourceType)
        backgroundCapability = try container.decodeIfPresent(DownloadBackgroundCapability.self, forKey: .backgroundCapability) ?? DownloadBackgroundCapability(sourceType: sourceType)
        progress = try container.decode(Double.self, forKey: .progress)
        bytesDownloaded = try container.decode(Int64.self, forKey: .bytesDownloaded)
        bytesTotal = try container.decode(Int64.self, forKey: .bytesTotal)
        speedBytesPerSec = try container.decode(Double.self, forKey: .speedBytesPerSec)
        resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData)
        backgroundSessionTaskIdentifier = try container.decodeIfPresent(Int.self, forKey: .backgroundSessionTaskIdentifier)
        stagingFilePath = try container.decodeIfPresent(String.self, forKey: .stagingFilePath)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)

        if let storedPath = try container.decodeIfPresent(String.self, forKey: .localFilePath) {
            localFilePath = Self.restoreLocalPath(from: storedPath)
        } else {
            localFilePath = nil
        }
    }

    private static func restoreLocalPath(from storedPath: String) -> String {
        let trimmedPath = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return storedPath }

        if let url = URL(string: trimmedPath), url.isFileURL {
            return restoreAbsoluteLocalPath(url.path)
        }

        if trimmedPath.hasPrefix("/") {
            return restoreAbsoluteLocalPath(trimmedPath)
        }

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return trimmedPath
        }
        return documentsURL.appendingPathComponent(trimmedPath).standardizedFileURL.path
    }

    private static func restoreAbsoluteLocalPath(_ rawPath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if FileManager.default.fileExists(atPath: standardizedPath) {
            return standardizedPath
        }

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let range = standardizedPath.range(of: "/Documents/") else {
            return standardizedPath
        }

        let relativePath = String(standardizedPath[range.upperBound...])
        return documentsURL.appendingPathComponent(relativePath).standardizedFileURL.path
    }

    static func relativeLocalPath(forRawPath rawPath: String) -> String? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let documentsPath = documentsURL.standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard standardizedPath == documentsPath || standardizedPath.hasPrefix(documentsPath + "/") else {
            return nil
        }

        let suffix = String(standardizedPath.dropFirst(documentsPath.count))
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
    }
}

public struct DownloadJobGroup: Identifiable {
    public enum Bucket {
        case active
        case completed
        case failed
    }

    public let id: UUID
    public let kind: DownloadJobKind
    public let sourceType: DownloadSourceType
    public let title: String
    public let groupTitle: String?
    public let serverId: UUID
    public let serverName: String
    public let createdAt: Date
    public let tasks: [DownloadTaskItem]
    
    public init(id: UUID, kind: DownloadJobKind, sourceType: DownloadSourceType, title: String, groupTitle: String? = nil, serverId: UUID, serverName: String, createdAt: Date, tasks: [DownloadTaskItem]) {
        self.id = id
        self.kind = kind
        self.sourceType = sourceType
        self.title = title
        self.groupTitle = groupTitle
        self.serverId = serverId
        self.serverName = serverName
        self.createdAt = createdAt
        self.tasks = tasks
    }

    public var itemCount: Int { tasks.count }
    public var completedCount: Int { tasks.filter { $0.status == .completed }.count }
    public var failedCount: Int { tasks.filter { $0.status == .failed }.count }
    public var pausedCount: Int { tasks.filter { $0.status == .paused }.count }
    public var canceledCount: Int { tasks.filter { $0.status == .canceled }.count }
    public var queuedCount: Int { tasks.filter { $0.status == .queued }.count }
    public var downloadingCount: Int { tasks.filter { $0.status == .downloading }.count }
    public var activeCount: Int { tasks.filter(\.isActive).count }
    public var isExpandable: Bool { tasks.count > 1 }

    public var bucket: Bucket? {
        if activeCount > 0 {
            return .active
        }
        if failedCount > 0 || canceledCount > 0 {
            return .failed
        }
        if completedCount > 0 {
            return .completed
        }
        return nil
    }

    public var primaryStatus: DownloadTaskStatus {
        if downloadingCount > 0 { return .downloading }
        if queuedCount > 0 { return .queued }
        if pausedCount > 0 { return .paused }
        if failedCount > 0 { return .failed }
        if canceledCount > 0 { return .canceled }
        if completedCount > 0 { return .completed }
        return .canceled
    }

    public var aggregateProgress: Double {
        guard !tasks.isEmpty else { return 0 }
        let total = tasks.reduce(0.0) { $0 + $1.progress }
        return total / Double(tasks.count)
    }

    public var totalBytes: Int64 {
        tasks.reduce(0) { $0 + max(max($1.bytesTotal, $1.bytesDownloaded), 0) }
    }

    // Only live transfers contribute; persisted completed tasks may retain old samples.
    public var speedBytesPerSec: Double {
        tasks.reduce(0.0) { total, task in
            guard task.status == .downloading else { return total }
            return total + max(task.speedBytesPerSec, 0)
        }
    }

    public var downloadedBytes: Int64 {
        tasks.reduce(0) { $0 + max($1.bytesDownloaded, 0) }
    }
}
