import Foundation

public protocol BackgroundDownloadSessionManagerDelegate: AnyObject {
    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didReconnectDownload id: UUID,
        sessionTaskIdentifier: Int,
        bytesDownloaded: Int64,
        totalBytes: Int64
    )

    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didUpdateDownload id: UUID,
        bytesDownloaded: Int64,
        totalBytes: Int64
    )

    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didFinishDownloading id: UUID,
        to stagingURL: URL
    )

    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didCompleteDownload id: UUID,
        error: Error?,
        resumeData: Data?
    )
}

public final class BackgroundDownloadSessionManager: NSObject {
    public static let shared = BackgroundDownloadSessionManager()

    public static var sessionIdentifier: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "GenPlayer"
        return "\(bundleIdentifier).downloads.background"
    }

    public weak var delegate: BackgroundDownloadSessionManagerDelegate?

    private var completionErrors: [Int: Error] = [:]
    private let lock = NSLock()
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        #if os(iOS)
        if #available(iOS 13.0, *) {
            configuration.allowsExpensiveNetworkAccess = true
            configuration.allowsConstrainedNetworkAccess = true
        }
        #endif
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    @discardableResult
    public func startDownload(id: UUID, request: URLRequest, resumeData: Data?) -> Int {
        let task: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }

        task.taskDescription = id.uuidString
        let identifier = task.taskIdentifier
        task.resume()
        return identifier
    }

    public func pauseDownload(id: UUID) {
        findDownloadTask(id: id) { task in
            task?.cancel(byProducingResumeData: { _ in })
        }
    }

    public func cancelDownload(id: UUID) {
        findDownloadTask(id: id) { task in
            task?.cancel()
        }
    }

    public func registerBackgroundCompletionHandler(
        for identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        lock.lock()
        backgroundCompletionHandlers[identifier] = completionHandler
        lock.unlock()
    }

    public func reconnectPersistedDownloads(
        persistedTasks: [DownloadTaskItem],
        completion: @escaping (Set<UUID>) -> Void
    ) {
        let trackedTasks = Dictionary(uniqueKeysWithValues: persistedTasks.map { ($0.id, $0) })

        session.getAllTasks { [weak self] sessionTasks in
            guard let self else {
                completion([])
                return
            }

            var activeDownloadIDs = Set<UUID>()

            for case let downloadTask as URLSessionDownloadTask in sessionTasks {
                guard let description = downloadTask.taskDescription,
                      let downloadID = UUID(uuidString: description) else {
                    downloadTask.cancel()
                    continue
                }

                guard let persistedTask = trackedTasks[downloadID],
                      persistedTask.backgroundCapability == .backgroundTransfer else {
                    downloadTask.cancel()
                    continue
                }

                switch persistedTask.status {
                case .queued, .downloading:
                    activeDownloadIDs.insert(downloadID)
                    let bytesDownloaded = max(persistedTask.bytesDownloaded, downloadTask.countOfBytesReceived)
                    let totalBytes = max(
                        persistedTask.bytesTotal,
                        max(0, downloadTask.countOfBytesExpectedToReceive)
                    )

                    self.notifyDelegate { delegate in
                        delegate.backgroundDownloadSessionManager(
                            self,
                            didReconnectDownload: downloadID,
                            sessionTaskIdentifier: downloadTask.taskIdentifier,
                            bytesDownloaded: bytesDownloaded,
                            totalBytes: totalBytes
                        )
                    }

                    if downloadTask.state == .suspended {
                        downloadTask.resume()
                    }

                case .paused, .completed, .failed, .canceled:
                    downloadTask.cancel()
                }
            }

            completion(activeDownloadIDs)
        }
    }

    private func findDownloadTask(
        id: UUID,
        completion: @escaping (URLSessionDownloadTask?) -> Void
    ) {
        session.getAllTasks { sessionTasks in
            let matchingTask = sessionTasks.compactMap { $0 as? URLSessionDownloadTask }.first {
                $0.taskDescription == id.uuidString
            }
            completion(matchingTask)
        }
    }

    private func notifyDelegate(_ block: @escaping (BackgroundDownloadSessionManagerDelegate) -> Void) {
        Task { @MainActor [weak self] in
            guard let delegate = self?.delegate else { return }
            block(delegate)
        }
    }

    private func consumeBackgroundCompletionHandler(for identifier: String) -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let handler = backgroundCompletionHandlers[identifier]
        backgroundCompletionHandlers[identifier] = nil
        return handler
    }

    private func stageDownloadedFile(from location: URL, downloadID: UUID, task: URLSessionDownloadTask) throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory: URL
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseDirectory = applicationSupport
        } else {
            baseDirectory = fileManager.temporaryDirectory
        }

        let stagingDirectory = baseDirectory
            .appendingPathComponent("GenPlayer", isDirectory: true)
            .appendingPathComponent("BackgroundDownloads", isDirectory: true)

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: nil)

        let suggestedName = bestFileName(for: task)
        let destinationURL = stagingDirectory
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
            .appendingPathComponent(suggestedName)

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.moveItem(at: location, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: location, to: destinationURL)
            try? fileManager.removeItem(at: location)
        }

        return destinationURL
    }

    private func bestFileName(for task: URLSessionDownloadTask) -> String {
        let candidates = [
            task.response?.suggestedFilename,
            task.originalRequest?.url?.lastPathComponent,
            task.currentRequest?.url?.lastPathComponent
        ]

        let resolved = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? UUID().uuidString

        let hasExtension = resolved.contains(".")
        return hasExtension ? resolved : "\(resolved).bin"
    }
}

extension BackgroundDownloadSessionManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let description = downloadTask.taskDescription,
              let downloadID = UUID(uuidString: description) else { return }

        notifyDelegate { delegate in
            delegate.backgroundDownloadSessionManager(
                self,
                didUpdateDownload: downloadID,
                bytesDownloaded: totalBytesWritten,
                totalBytes: max(0, totalBytesExpectedToWrite)
            )
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription,
              let downloadID = UUID(uuidString: description) else { return }

        do {
            try DownloadFileValidation.validateHTTP(response: downloadTask.response, fileURL: location)
            let stagingURL = try stageDownloadedFile(from: location, downloadID: downloadID, task: downloadTask)
            notifyDelegate { delegate in
                delegate.backgroundDownloadSessionManager(
                    self,
                    didFinishDownloading: downloadID,
                    to: stagingURL
                )
            }
        } catch {
            lock.lock()
            completionErrors[downloadTask.taskIdentifier] = error
            lock.unlock()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let description = task.taskDescription,
              let downloadID = UUID(uuidString: description) else { return }

        lock.lock()
        let completionError = completionErrors.removeValue(forKey: task.taskIdentifier) ?? error
        lock.unlock()
        let resumeData = (completionError as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        notifyDelegate { delegate in
            delegate.backgroundDownloadSessionManager(
                self,
                didCompleteDownload: downloadID,
                error: completionError,
                resumeData: resumeData
            )
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let handler = consumeBackgroundCompletionHandler(for: session.configuration.identifier ?? "") else { return }
        DispatchQueue.main.async {
            handler()
        }
    }
}
