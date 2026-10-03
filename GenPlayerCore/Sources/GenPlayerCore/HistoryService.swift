import Foundation
import Combine

public struct PlaybackProgressSnapshot {
    public let progress: Double
    public let isFinished: Bool

    public init(progress: Double, isFinished: Bool) {
        self.progress = min(max(progress, 0), 1)
        self.isFinished = isFinished
    }

    public var displayedProgress: Double {
        isFinished ? 1.0 : progress
    }
}

public extension PlaybackProgressSnapshot {
    private static let completionThreshold = 0.90

    static func fromFraction(_ fraction: Double?, played: Bool = false) -> PlaybackProgressSnapshot? {
        let clamped = min(max(fraction ?? 0, 0), 1)
        guard played || clamped > 0 else { return nil }

        // If the server still marks an item as watched but also reports a fresh
        // resume position, prefer showing the active resume progress instead of
        // a completed badge. This keeps "re-watch from the middle" visually honest.
        if clamped > 0, clamped < completionThreshold {
            return PlaybackProgressSnapshot(
                progress: clamped,
                isFinished: false
            )
        }

        return PlaybackProgressSnapshot(
            progress: 1.0,
            isFinished: played || clamped >= completionThreshold
        )
    }

    static func fromPercent(_ percentage: Double?, played: Bool = false) -> PlaybackProgressSnapshot? {
        guard let percentage else {
            return played ? PlaybackProgressSnapshot(progress: 1.0, isFinished: true) : nil
        }
        return fromFraction(percentage / 100.0, played: played)
    }
}

public struct RemotePlaybackResumeDecision {
    public static let none = RemotePlaybackResumeDecision(
        startPosition: nil,
        progressSnapshot: nil,
        shouldResetPlayedStateOnStart: false
    )

    public let startPosition: TimeInterval?
    public let progressSnapshot: PlaybackProgressSnapshot?
    public let shouldResetPlayedStateOnStart: Bool

    public init(
        startPosition: TimeInterval?,
        progressSnapshot: PlaybackProgressSnapshot?,
        shouldResetPlayedStateOnStart: Bool
    ) {
        self.startPosition = startPosition
        self.progressSnapshot = progressSnapshot
        self.shouldResetPlayedStateOnStart = shouldResetPlayedStateOnStart
    }

    public var shouldContinuePlayback: Bool {
        guard let startPosition else { return false }
        return startPosition > 0 && !shouldResetPlayedStateOnStart
    }
}

public extension RemotePlaybackResumeDecision {
    static func fromServerPlaybackState(
        playbackTicks: Int64?,
        runtimeTicks: Int64?,
        playedPercentage: Double?,
        played: Bool = false
    ) -> RemotePlaybackResumeDecision {
        let positionSeconds = playbackTicks.map { max(Double($0) / 10_000_000.0, 0) } ?? 0
        let progressSnapshot: PlaybackProgressSnapshot?

        if let playedPercentage {
            progressSnapshot = PlaybackProgressSnapshot.fromPercent(playedPercentage, played: played)
        } else if let playbackTicks, playbackTicks > 0, let runtimeTicks, runtimeTicks > 0 {
            progressSnapshot = PlaybackProgressSnapshot.fromFraction(
                Double(playbackTicks) / Double(runtimeTicks),
                played: played
            )
        } else if played {
            progressSnapshot = PlaybackProgressSnapshot(progress: 1.0, isFinished: true)
        } else {
            progressSnapshot = nil
        }

        if progressSnapshot?.isFinished == true {
            // Keep an explicit zero so the player will start from the beginning
            // instead of falling back to stale local history.
            return RemotePlaybackResumeDecision(
                startPosition: 0,
                progressSnapshot: progressSnapshot,
                shouldResetPlayedStateOnStart: true
            )
        }

        return RemotePlaybackResumeDecision(
            startPosition: positionSeconds > 0 ? positionSeconds : nil,
            progressSnapshot: progressSnapshot,
            shouldResetPlayedStateOnStart: false
        )
    }

    static func fromPlaybackPosition(
        positionSeconds: TimeInterval,
        progressFraction: Double?,
        played: Bool = false
    ) -> RemotePlaybackResumeDecision {
        let clampedPosition = max(positionSeconds, 0)
        let progressSnapshot: PlaybackProgressSnapshot?

        if let progressFraction {
            progressSnapshot = PlaybackProgressSnapshot.fromFraction(progressFraction, played: played)
        } else if played {
            progressSnapshot = PlaybackProgressSnapshot(progress: 1.0, isFinished: true)
        } else {
            progressSnapshot = nil
        }

        if progressSnapshot?.isFinished == true {
            return RemotePlaybackResumeDecision(
                startPosition: 0,
                progressSnapshot: progressSnapshot,
                shouldResetPlayedStateOnStart: true
            )
        }

        return RemotePlaybackResumeDecision(
            startPosition: clampedPosition > 0 ? clampedPosition : nil,
            progressSnapshot: progressSnapshot,
            shouldResetPlayedStateOnStart: false
        )
    }
}

public class HistoryService: ObservableObject {
    public static let shared = HistoryService()
    
    @Published public var localHistory: [VideoFile] = []
    @Published public var remoteHistory: [VideoFile] = []
    
    // Legacy key for migration
    private let legacyHistoryKey = "playback_history"
    
    // New keys
    private let localHistoryKey = "playback_history_local"
    private let remoteHistoryKey = "playback_history_remote"
    
    private init() {
        loadHistory()
    }
    
    public var allHistory: [VideoFile] {
        return (localHistory + remoteHistory).map { file in
            var refreshedFile = file
            if let pos = file.lastPlayedPosition, let dur = file.duration, dur > 0 {
                if Self.playbackIsFinished(position: pos, duration: dur) {
                    refreshedFile.shouldResetRemotePlayedStateOnPlaybackStart = true
                }
            }
            return refreshedFile
        }.sorted(by: { $0.date > $1.date })
    }

    public static func isHistoryEnabled(
        for file: VideoFile,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch file.type {
        case .video:
            return boolDefaultingToTrue(forKey: "enableVideoHistory", defaults: defaults)
        case .audio:
            return boolDefaultingToTrue(forKey: "enableAudioHistory", defaults: defaults)
        default:
            return true
        }
    }

    private static func boolDefaultingToTrue(
        forKey key: String,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
    
    /// Reload history from disk
    public func refresh() {
        loadHistory()
    }

    public static func normalizedPlaybackProgress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, position > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    public static func playbackIsFinished(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 0, position > 0 else { return false }

        let percentage = normalizedPlaybackProgress(position: position, duration: duration)
        let remaining = max(duration - position, 0)
        let isShortVideo = duration < 600 // 10 minutes

        if isShortVideo {
            return percentage > 0.90
        }

        return percentage > 0.90 || remaining < 180
    }

    public func playbackProgressSnapshot(matching file: VideoFile) -> PlaybackProgressSnapshot? {
        let candidate = allHistory.first(where: { isSameFile($0.url, file.url) }) ?? file

        guard let duration = candidate.duration,
              let position = candidate.lastPlayedPosition,
              duration > 0,
              position > 0 else {
            return nil
        }

        return PlaybackProgressSnapshot(
            progress: Self.normalizedPlaybackProgress(position: position, duration: duration),
            isFinished: Self.playbackIsFinished(position: position, duration: duration)
        )
    }
    
    /// Compare file paths (more reliable than URL comparison)
    /// Compare file paths (more reliable than URL comparison)
    private func isSameFile(_ url1: URL, _ url2: URL) -> Bool {
        if url1 == url2 { return true }
        if url1.standardizedFileURL.path == url2.standardizedFileURL.path { return true }
        
        // Handle Sandbox Path Changes for Local Files (App Updates change the container UUID)
        if url1.isFileURL && url2.isFileURL {
            // Check if filenames match as a fallback (robust against path changes)
            if url1.lastPathComponent == url2.lastPathComponent {
                return true
            }
        }
        
        return false
    }

    private func isSameFile(_ file1: VideoFile, _ file2: VideoFile) -> Bool {
        if file1.url == file2.url { return true }
        if file1.url.isFileURL && file2.url.isFileURL && file1.url.standardizedFileURL.path == file2.url.standardizedFileURL.path { return true }

        if let j1 = file1.jellyfinItemId, !j1.isEmpty,
           let j2 = file2.jellyfinItemId, !j2.isEmpty,
           let s1 = file1.jellyfinServerId, !s1.isEmpty,
           let s2 = file2.jellyfinServerId, !s2.isEmpty,
           j1 == j2 && s1 == s2 {
            return true
        }

        if let s1 = file1.jellyfinServerId, !s1.isEmpty,
           let s2 = file2.jellyfinServerId, !s2.isEmpty,
           let p1 = file1.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p1.isEmpty,
           let p2 = file2.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p2.isEmpty,
           s1 == s2 && p1 == p2 {
            return true
        }

        if file1.isRemote && file2.isRemote {
            if let p1 = file1.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p1.isEmpty,
               let p2 = file2.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p2.isEmpty,
               p1 == p2 {
                return true
            }
        }

        let path1 = file1.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (file1.url.isFileURL ? file1.url.path : nil)
        let path2 = file2.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (file2.url.isFileURL ? file2.url.path : nil)
        if let p1 = path1, !p1.isEmpty, let p2 = path2, !p2.isEmpty, p1 == p2 {
            if let s1 = file1.jellyfinServerId, let s2 = file2.jellyfinServerId, !s1.isEmpty, !s2.isEmpty {
                if s1 == s2 { return true }
            } else {
                return true
            }
        }

        return isSameFile(file1.url, file2.url)
    }
    
    public func addToHistory(_ file: VideoFile) {
        let fileToAdd = file
        
        if file.isRemote {
            addToRemoteHistory(fileToAdd)
        } else {
            addToLocalHistory(fileToAdd)
        }
    }
    
    private func addToLocalHistory(_ file: VideoFile) {
        var fileToAdd = file
        if let index = localHistory.firstIndex(where: { isSameFile($0, file) }) {
             let existing = localHistory[index]
             fileToAdd.lastPlayedPosition = existing.lastPlayedPosition
             fileToAdd.duration = existing.duration
             fileToAdd.videoAspectRatioHint = fileToAdd.videoAspectRatioHint ?? existing.videoAspectRatioHint
             fileToAdd.lastAudioTrack = existing.lastAudioTrack
             fileToAdd.lastSubtitleTrack = existing.lastSubtitleTrack
             localHistory.remove(at: index)
        }
        localHistory.insert(fileToAdd, at: 0)
        if localHistory.count > 50 { localHistory.removeLast() }
        saveLocalHistory()
    }
    
    private func addToRemoteHistory(_ file: VideoFile) {
        var fileToAdd = file
        if (fileToAdd.serverType?.requiresDynamicPlaybackURL == true), let serverPath = fileToAdd.serverPath, !serverPath.isEmpty {
            fileToAdd.url = URL(fileURLWithPath: serverPath)
        }
        if let index = remoteHistory.firstIndex(where: { isSameFile($0, fileToAdd) }) {
             let existing = remoteHistory[index]
             fileToAdd.lastPlayedPosition = existing.lastPlayedPosition
             fileToAdd.duration = existing.duration
             fileToAdd.videoAspectRatioHint = fileToAdd.videoAspectRatioHint ?? existing.videoAspectRatioHint
             fileToAdd.lastAudioTrack = existing.lastAudioTrack
             fileToAdd.lastSubtitleTrack = existing.lastSubtitleTrack
             remoteHistory.remove(at: index)
        }
        remoteHistory.insert(fileToAdd, at: 0)
        if remoteHistory.count > 50 { remoteHistory.removeLast() }
        saveRemoteHistory()
    }

    private func refreshedHistoryFile(
        from existing: VideoFile,
        time: TimeInterval,
        duration: TimeInterval,
        videoAspectRatioHint: Double?,
        audioTrack: Int?,
        subtitleTrack: Int?,
        jellyfinItemId: String?,
        jellyfinServerId: String?,
        externalSubtitleCandidates: [ExternalSubtitleCandidate]?,
        serverPath: String? = nil
    ) -> VideoFile {
        var file = existing
        file.lastPlayedPosition = time
        file.duration = duration
        if let videoAspectRatioHint {
            file.videoAspectRatioHint = videoAspectRatioHint
        }
        file.date = Date()
        if let audio = audioTrack { file.lastAudioTrack = audio }
        if let subtitle = subtitleTrack { file.lastSubtitleTrack = subtitle }
        if let jId = jellyfinItemId { file.jellyfinItemId = jId }
        if let sId = jellyfinServerId { file.jellyfinServerId = sId }
        if let path = serverPath, !path.isEmpty {
            file.serverPath = path
            if file.serverType?.requiresDynamicPlaybackURL == true {
                file.url = URL(fileURLWithPath: path)
            }
        }
        if let externalSubtitleCandidates {
            file.externalSubtitleCandidates = externalSubtitleCandidates
        }
        return file
    }

    private func remoteHistoryIndex(
        matchingItemId jellyfinItemId: String?,
        serverId jellyfinServerId: String?
    ) -> Int? {
        guard let jellyfinItemId = jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jellyfinItemId.isEmpty,
              let jellyfinServerId = jellyfinServerId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jellyfinServerId.isEmpty else {
            return nil
        }

        return remoteHistory.firstIndex { file in
            file.jellyfinItemId == jellyfinItemId && file.jellyfinServerId == jellyfinServerId
        }
    }
    
    public func updateProgress(
        for fileUrl: URL,
        time: TimeInterval,
        duration: TimeInterval,
        videoAspectRatioHint: Double? = nil,
        audioTrack: Int? = nil,
        subtitleTrack: Int? = nil,
        jellyfinItemId: String? = nil,
        jellyfinServerId: String? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate]? = nil,
        serverPath: String? = nil
    ) -> VideoFile? {
        let isRemote = (jellyfinServerId != nil && !jellyfinServerId!.isEmpty) || (serverPath != nil && !serverPath!.isEmpty) || fileUrl.scheme == "smb" || fileUrl.scheme == "http" || fileUrl.scheme == "https" || fileUrl.absoluteString.hasPrefix("smb://")
        var tempFile = VideoFile(
            name: "",
            url: fileUrl,
            type: .video,
            size: 0,
            date: Date(),
            isRemote: isRemote,
            jellyfinItemId: jellyfinItemId,
            jellyfinServerId: jellyfinServerId
        )
        tempFile.serverPath = serverPath

        // Check local first
        if let index = localHistory.firstIndex(where: { isSameFile($0, tempFile) }) {
            let file = refreshedHistoryFile(
                from: localHistory[index],
                time: time,
                duration: duration,
                videoAspectRatioHint: videoAspectRatioHint,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack,
                jellyfinItemId: jellyfinItemId,
                jellyfinServerId: jellyfinServerId,
                externalSubtitleCandidates: externalSubtitleCandidates,
                serverPath: serverPath
            )
            localHistory.remove(at: index)
            localHistory.insert(file, at: 0)
            saveLocalHistory()
            return file
        }
        
        // Check remote
        if let index = remoteHistory.firstIndex(where: { isSameFile($0, tempFile) }) {
            let file = refreshedHistoryFile(
                from: remoteHistory[index],
                time: time,
                duration: duration,
                videoAspectRatioHint: videoAspectRatioHint,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack,
                jellyfinItemId: jellyfinItemId,
                jellyfinServerId: jellyfinServerId,
                externalSubtitleCandidates: externalSubtitleCandidates,
                serverPath: serverPath
            )
            remoteHistory.remove(at: index)
            remoteHistory.insert(file, at: 0)
            saveRemoteHistory()
            return file
        }

        // Offline playback logic fallback
        if let index = remoteHistoryIndex(matchingItemId: jellyfinItemId, serverId: jellyfinServerId) {
            let file = refreshedHistoryFile(
                from: remoteHistory[index],
                time: time,
                duration: duration,
                videoAspectRatioHint: videoAspectRatioHint,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack,
                jellyfinItemId: jellyfinItemId,
                jellyfinServerId: jellyfinServerId,
                externalSubtitleCandidates: externalSubtitleCandidates
            )
            remoteHistory.remove(at: index)
            remoteHistory.insert(file, at: 0)
            saveRemoteHistory()
            return file
        }
        
        return nil
    }

    public func resetPlaybackProgress(
        for fileUrl: URL,
        preferredDuration: TimeInterval? = nil,
        videoAspectRatioHint: Double? = nil,
        audioTrack: Int? = nil,
        subtitleTrack: Int? = nil,
        jellyfinItemId: String? = nil,
        jellyfinServerId: String? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate]? = nil
    ) -> VideoFile? {
        let isRemote = fileUrl.scheme == "smb" || fileUrl.scheme == "http" || fileUrl.scheme == "https" || fileUrl.absoluteString.hasPrefix("smb://")
        let tempFile = VideoFile(
            name: "",
            url: fileUrl,
            type: .video,
            size: 0,
            date: Date(),
            isRemote: isRemote,
            jellyfinItemId: jellyfinItemId,
            jellyfinServerId: jellyfinServerId
        )
        func resetHistoryFile(_ existing: VideoFile) -> VideoFile {
            let preservedDuration = preferredDuration ?? existing.duration ?? 0
            return refreshedHistoryFile(
                from: existing,
                time: 0,
                duration: preservedDuration,
                videoAspectRatioHint: videoAspectRatioHint,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack,
                jellyfinItemId: jellyfinItemId,
                jellyfinServerId: jellyfinServerId,
                externalSubtitleCandidates: externalSubtitleCandidates
            )
        }

        if let index = localHistory.firstIndex(where: { isSameFile($0.url, fileUrl) }) {
            let file = resetHistoryFile(localHistory[index])
            localHistory.remove(at: index)
            localHistory.insert(file, at: 0)
            saveLocalHistory()
            return file
        }

        if let index = remoteHistory.firstIndex(where: { isSameFile($0.url, fileUrl) }) {
            let file = resetHistoryFile(remoteHistory[index])
            remoteHistory.remove(at: index)
            remoteHistory.insert(file, at: 0)
            saveRemoteHistory()
            return file
        }

        if let index = remoteHistoryIndex(matchingItemId: jellyfinItemId, serverId: jellyfinServerId) {
            let file = resetHistoryFile(remoteHistory[index])
            remoteHistory.remove(at: index)
            remoteHistory.insert(file, at: 0)
            saveRemoteHistory()
            return file
        }

        return nil
    }
    
    public func getLastPlayedPosition(for file: VideoFile) -> TimeInterval? {
        let matched: VideoFile?
        if let local = localHistory.first(where: { isSameFile($0, file) }) {
            matched = local
        } else if let remote = remoteHistory.first(where: { isSameFile($0, file) }) {
            matched = remote
        } else {
            return getLastPlayedPosition(for: file.url)
        }
        
        guard let historyFile = matched else {
            return nil
        }
        
        let position = historyFile.lastPlayedPosition ?? 0
        guard position > 0 else {
            return nil
        }
        
        if let duration = historyFile.duration, duration > 0 {
            if Self.playbackIsFinished(position: position, duration: duration) {
                return nil
            }
        }
        
        return position
    }

    public func getLastPlayedPosition(for fileUrl: URL) -> TimeInterval? {
        let file: VideoFile?
        if let local = localHistory.first(where: { isSameFile($0.url, fileUrl) }) {
            file = local
        } else {
            file = remoteHistory.first(where: { isSameFile($0.url, fileUrl) })
        }
        
        guard let historyFile = file else {
            return nil
        }
        
        let position = historyFile.lastPlayedPosition ?? 0
        guard position > 0 else {
            return nil
        }
        
        if let duration = historyFile.duration, duration > 0 {
            if Self.playbackIsFinished(position: position, duration: duration) {
                return nil
            }
        }
        
        return position
    }

    private func queryFile(from item: MediaItem) -> VideoFile {
        let isRemote = item.isRemote || (item.jellyfinServerId != nil && !item.jellyfinServerId!.isEmpty) || (item.serverPath != nil && !item.serverPath!.isEmpty)
        var file = VideoFile(
            name: item.title,
            url: item.url,
            type: .video,
            size: 0,
            date: Date(),
            isRemote: isRemote,
            jellyfinItemId: item.jellyfinItemId,
            jellyfinServerId: item.jellyfinServerId
        )
        file.serverType = item.serverType
        file.serverPath = item.serverPath
        return file
    }

    public func getLastPlayedPosition(for item: MediaItem) -> TimeInterval? {
        getLastPlayedPosition(for: queryFile(from: item))
    }

    public func getLastTrackSelection(for file: VideoFile) -> (audio: Int?, subtitle: Int?)? {
        if let matched = localHistory.first(where: { isSameFile($0, file) }) {
            return (matched.lastAudioTrack, matched.lastSubtitleTrack)
        }
        if let matched = remoteHistory.first(where: { isSameFile($0, file) }) {
            return (matched.lastAudioTrack, matched.lastSubtitleTrack)
        }
        return getLastTrackSelection(for: file.url)
    }

    public func getLastTrackSelection(for item: MediaItem) -> (audio: Int?, subtitle: Int?)? {
        getLastTrackSelection(for: queryFile(from: item))
    }

    public func getLastTrackSelection(for fileUrl: URL) -> (audio: Int?, subtitle: Int?)? {
        if let file = localHistory.first(where: { isSameFile($0.url, fileUrl) }) {
             return (file.lastAudioTrack, file.lastSubtitleTrack)
        }
        if let file = remoteHistory.first(where: { isSameFile($0.url, fileUrl) }) {
             return (file.lastAudioTrack, file.lastSubtitleTrack)
        }
        return nil
    }
    
    public func removeFromHistory(_ file: VideoFile) {
        if file.isRemote {
            remoteHistory.removeAll(where: { isSameFile($0.url, file.url) })
            saveRemoteHistory()
        } else {
            localHistory.removeAll(where: { isSameFile($0.url, file.url) })
            saveLocalHistory()
        }
    }
    
    public func clearHistory(for files: [VideoFile]) {
        let localFiles = files.filter { !$0.isRemote }
        let remoteFiles = files.filter { $0.isRemote }
        
        if !localFiles.isEmpty {
            localHistory.removeAll { localFile in
                localFiles.contains(where: { isSameFile($0.url, localFile.url) })
            }
            saveLocalHistory()
        }
        
        if !remoteFiles.isEmpty {
            remoteHistory.removeAll { remoteFile in
                remoteFiles.contains(where: { isSameFile($0.url, remoteFile.url) })
            }
            saveRemoteHistory()
        }
    }
    
    public func clearHistory() {
        localHistory.removeAll()
        remoteHistory.removeAll()
        saveLocalHistory()
        saveRemoteHistory()
        UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
    }

    public func clearHistory(excludingPrivate: Bool) {
        if !excludingPrivate {
            clearHistory()
            return
        }
        let privacySpace = PrivacySpaceService.shared
        localHistory.removeAll { !privacySpace.isFileMarkedPrivate($0) }
        remoteHistory.removeAll { !privacySpace.isFileMarkedPrivate($0) }
        saveLocalHistory()
        saveRemoteHistory()
    }
    
    public func clearHistory(for server: ServerConfig) {
        remoteHistory.removeAll { file in
            belongsToServer(file, server: server)
        }
        saveRemoteHistory()
    }

    private func belongsToServer(_ file: VideoFile, server: ServerConfig) -> Bool {
        guard file.isRemote else { return false }
        return file.jellyfinServerId == server.id.uuidString
    }

    private func saveLocalHistory() {
        if let encoded = try? JSONEncoder().encode(localHistory) {
            UserDefaults.standard.set(encoded, forKey: localHistoryKey)
        }
    }
    
    private func saveRemoteHistory() {
        if let encoded = try? JSONEncoder().encode(remoteHistory) {
            UserDefaults.standard.set(encoded, forKey: remoteHistoryKey)
        }
    }
    
    private func loadHistory() {
        let hasLocal = loadLocalHistory()
        let hasRemote = loadRemoteHistory()
        
        if !hasLocal && !hasRemote {
            if let data = UserDefaults.standard.data(forKey: legacyHistoryKey),
               let legacyHistory = try? JSONDecoder().decode([VideoFile].self, from: data) {
                 
                var newLocal: [VideoFile] = []
                var newRemote: [VideoFile] = []
                
                for var file in legacyHistory {
                    let scheme = file.url.scheme?.lowercased() ?? ""
                    if scheme == "smb" || scheme == "http" || scheme == "https" || file.url.absoluteString.hasPrefix("smb://") {
                        file.isRemote = true
                        newRemote.append(file)
                    } else {
                        file.isRemote = false
                        newLocal.append(file)
                    }
                }
                
                self.localHistory = newLocal
                self.remoteHistory = newRemote
                
                saveLocalHistory()
                saveRemoteHistory()
                UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
            }
        } else {
            let incorrectlyLocal = localHistory.filter {
                let scheme = $0.url.scheme?.lowercased() ?? ""
                return scheme == "smb" || scheme == "http" || scheme == "https"
            }
            if !incorrectlyLocal.isEmpty {
                for file in incorrectlyLocal {
                    var fileToMove = file
                    fileToMove.isRemote = true
                    if !remoteHistory.contains(where: { isSameFile($0.url, file.url) }) {
                        remoteHistory.append(fileToMove)
                    }
                }
                localHistory.removeAll {
                    let scheme = $0.url.scheme?.lowercased() ?? ""
                    return scheme == "smb" || scheme == "http" || scheme == "https"
                }
                remoteHistory.sort { ($0.date) > ($1.date) }
                saveLocalHistory()
                saveRemoteHistory()
            }
        }
    }
    
    private func loadLocalHistory() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: localHistoryKey) else { return false }
        
        do {
            let decoded = try JSONDecoder().decode([VideoFile].self, from: data)
            var validatedHistory: [VideoFile] = []
            let fileManager = FileManager.default
            
            guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                self.localHistory = decoded
                return true
            }
            
            for var file in decoded {
                if !file.isRemote {
                    if fileManager.fileExists(atPath: file.url.path) {
                        validatedHistory.append(file)
                        continue
                    }
                    
                    let pathComponents = file.url.pathComponents
                    if let docIndex = pathComponents.lastIndex(of: "Documents"), docIndex < pathComponents.count - 1 {
                        let relativeComponents = pathComponents[(docIndex+1)...]
                        let relativePath = relativeComponents.joined(separator: "/")
                        let newURL = documentsURL.appendingPathComponent(relativePath)
                        
                        if fileManager.fileExists(atPath: newURL.path) {
                            file.url = newURL
                            validatedHistory.append(file)
                            continue
                        }
                    }
                    
                    let flatURL = documentsURL.appendingPathComponent(file.url.lastPathComponent)
                    if fileManager.fileExists(atPath: flatURL.path) {
                        file.url = flatURL
                        validatedHistory.append(file)
                        continue
                    }
                } else {
                    validatedHistory.append(file)
                }
            }
            
            self.localHistory = validatedHistory
            saveLocalHistory()
            return true
        } catch {
            return false
        }
    }
    
    private func sanitizeRemoteHistory(_ history: [VideoFile]) -> [VideoFile] {
        return history.map { originalFile in
            var file = originalFile
            if file.serverType == .alist || file.serverType == .pan115 {
                if let path = file.serverPath, (path.hasPrefix("/d/") || path.contains("rawPath:")) {
                    file.serverPath = nil
                }
                if file.url.path.hasPrefix("/d/") || file.url.scheme == "http" || file.url.scheme == "https" {
                    if let path = file.serverPath, !path.isEmpty {
                        file.url = URL(fileURLWithPath: path)
                    } else {
                        file.url = URL(fileURLWithPath: "/\(file.name)")
                    }
                }
            }
            return file
        }
    }

    private func loadRemoteHistory() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: remoteHistoryKey) else { return false }
        if let decoded = try? JSONDecoder().decode([VideoFile].self, from: data) {
            self.remoteHistory = sanitizeRemoteHistory(decoded)
            return true
        }
        return false
    }
}
