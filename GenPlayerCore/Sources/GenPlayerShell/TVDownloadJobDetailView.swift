#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


enum TVDownloadListFilter: CaseIterable, Equatable, Hashable {
    case active
    case completed
    case failed

    var titleKey: String {
        switch self {
        case .active: return "Active"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var systemImageName: String {
        switch self {
        case .active: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var cleanupStatuses: [DownloadTaskStatus]? {
        switch self {
        case .active:
            return nil
        case .completed:
            return [.completed]
        case .failed:
            return [.failed, .canceled]
        }
    }
}



enum TVDownloadDestructiveKind {
    case cancelDownloads
    case deleteFiles
    case deleteRecords
}



struct TVDownloadPendingDestructiveAction: Identifiable {
    let kind: TVDownloadDestructiveKind
    let recordCount: Int
    let message: String
    let sectionDate: Date?
    let statuses: [DownloadTaskStatus]?
    let jobId: UUID?
    var taskId: UUID? = nil

    var id: String {
        let jobPart = jobId?.uuidString ?? "all"
        let taskPart = taskId?.uuidString ?? "none"
        let datePart = sectionDate.map { "\($0.timeIntervalSince1970)" } ?? "none"
        return "\(kind)-\(jobPart)-\(taskPart)-\(datePart)-\(recordCount)"
    }
}



struct TVDownloadDateGroup: Identifiable {
    let date: Date
    let jobs: [DownloadJobGroup]

    var id: Date { date }
}



struct TVDownloadJobMenuSnapshot: Equatable {
    let canPauseOrResume: Bool
    let isPaused: Bool
    let canRetry: Bool
    let canCleanUp: Bool
    let itemCount: Int

    init(job: DownloadJobGroup) {
        canPauseOrResume = job.bucket == .active
        isPaused = job.primaryStatus == .paused
        canRetry = job.bucket == .failed
        canCleanUp = job.bucket == .completed || job.bucket == .failed
        itemCount = job.itemCount
    }
}



struct TVDownloadJobContextMenuContent: View, Equatable {
    let snapshot: TVDownloadJobMenuSnapshot
    let pauseOrResume: () -> Void
    let retry: () -> Void
    let cancel: () -> Void
    let deleteFiles: () -> Void
    let deleteRecords: () -> Void

    static func == (lhs: TVDownloadJobContextMenuContent, rhs: TVDownloadJobContextMenuContent) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        if snapshot.canPauseOrResume {
            Button(action: pauseOrResume) {
                Label(
                    platformShellString(snapshot.isPaused ? "Resume Download" : "Pause Download"),
                    systemImage: snapshot.isPaused ? "play.fill" : "pause.fill"
                )
            }

            tvDestructiveMenuButton(
                title: platformShellString("Cancel Download"),
                systemImageName: "xmark.circle",
                action: cancel
            )
        } else if snapshot.canRetry {
            Button(action: retry) {
                Label(platformShellString("Retry Download"), systemImage: "arrow.clockwise")
            }
        }

        if snapshot.canCleanUp {
            tvDestructiveMenuButton(
                title: platformShellString(snapshot.itemCount > 1 ? "Delete Files" : "Delete File"),
                systemImageName: "trash",
                action: deleteFiles
            )

            tvDestructiveMenuButton(
                title: platformShellString(snapshot.itemCount > 1 ? "Delete Records" : "Delete Record"),
                systemImageName: "minus.circle",
                action: deleteRecords
            )
        }
    }
}



struct TVDownloadTaskMenuSnapshot: Equatable {
    let isPaused: Bool
    let isRunning: Bool
    let canRetry: Bool
    let canCleanUp: Bool

    init(task: DownloadTaskItem) {
        isPaused = task.status == .paused
        isRunning = task.status == .queued || task.status == .downloading
        canRetry = task.status == .failed || task.status == .canceled
        canCleanUp = task.status == .completed || task.status == .failed || task.status == .canceled
    }
}



struct TVDownloadTaskContextMenuContent: View, Equatable {
    let snapshot: TVDownloadTaskMenuSnapshot
    let pause: () -> Void
    let resume: () -> Void
    let retry: () -> Void
    let cancel: () -> Void
    let deleteFile: () -> Void
    let deleteRecord: () -> Void

    static func == (lhs: TVDownloadTaskContextMenuContent, rhs: TVDownloadTaskContextMenuContent) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        if snapshot.isPaused {
            Button(action: resume) {
                Label(platformShellString("Resume Download"), systemImage: "play.fill")
            }
        } else if snapshot.isRunning {
            Button(action: pause) {
                Label(platformShellString("Pause Download"), systemImage: "pause.fill")
            }

            tvDestructiveMenuButton(
                title: platformShellString("Cancel Download"),
                systemImageName: "xmark.circle",
                action: cancel
            )
        } else if snapshot.canRetry {
            Button(action: retry) {
                Label(platformShellString("Retry Download"), systemImage: "arrow.clockwise")
            }
        }

        if snapshot.canCleanUp {
            tvDestructiveMenuButton(
                title: platformShellString("Delete File"),
                systemImageName: "trash",
                action: deleteFile
            )

            tvDestructiveMenuButton(
                title: platformShellString("Delete Record"),
                systemImageName: "minus.circle",
                action: deleteRecord
            )
        }
    }
}



struct TVDownloadDateSection<RowMenu: View>: View {
    let title: String
    let jobs: [DownloadJobGroup]
    let headerAccessory: AnyView?
    let rowContextMenu: (DownloadJobGroup) -> RowMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)

                Text("\(jobs.count)")
                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                    .foregroundColor(TVShellStyle.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TVShellStyle.surface)
                    )

                if let headerAccessory {
                    headerAccessory
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvFocusSectionIfAvailable()

            LazyVStack(spacing: 14) {
                ForEach(jobs) { job in
                    NavigationLink(destination: TVDownloadJobDetailView(jobId: job.id)) {
                        TVDownloadJobListRow(job: job)
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    .contextMenu {
                        rowContextMenu(job)
                    }
                }
            }
        }
        .tvFocusSectionIfAvailable()
    }
}



struct TVDownloadsOverviewPanel: View {
    let activeJobs: [DownloadJobGroup]
    let completedJobs: [DownloadJobGroup]
    let failedJobs: [DownloadJobGroup]
    let storageSummary: DownloadCenterService.DownloadedStorageSummary

    private var activeTaskCount: Int {
        activeJobs.reduce(0) { $0 + $1.activeCount }
    }

    private var completedTaskCount: Int {
        completedJobs.reduce(0) { $0 + $1.completedCount }
    }

    private var failedTaskCount: Int {
        failedJobs.reduce(0) { $0 + $1.failedCount + $1.canceledCount }
    }

    private var totalJobCount: Int {
        activeJobs.count + completedJobs.count + failedJobs.count
    }

    private var activeProgress: Double {
        let allTasks = activeJobs.flatMap(\.tasks)
        guard !allTasks.isEmpty else { return 0 }
        let total = allTasks.reduce(0.0) { $0 + $1.progress }
        return min(max(total / Double(allTasks.count), 0), 1)
    }

    private var progressText: String {
        "\(Int(activeProgress * 100))%"
    }

    private var idleStatusText: String {
        failedTaskCount > 0 ? platformShellString("Failed") : platformShellString("Completed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                TVDownloadOverviewMetric(
                    title: platformShellString("Active"),
                    value: "\(activeTaskCount)",
                    systemImageName: "arrow.down.circle.fill",
                    tint: TVShellStyle.accentSoft,
                    isPrimary: true
                )

                TVDownloadOverviewMetric(
                    title: platformShellString("Completed"),
                    value: "\(completedTaskCount)",
                    systemImageName: "checkmark.circle.fill",
                    tint: Color(red: 0.48, green: 0.88, blue: 0.62)
                )

                TVDownloadOverviewMetric(
                    title: platformShellString("Failed"),
                    value: "\(failedTaskCount)",
                    systemImageName: "exclamationmark.triangle.fill",
                    tint: Color(red: 1.0, green: 0.48, blue: 0.40)
                )

                TVDownloadOverviewMetric(
                    title: platformShellString("Storage Summary"),
                    value: tvByteCountString(storageSummary.totalBytes),
                    systemImageName: "externaldrive.fill",
                    tint: Color.white.opacity(0.82)
                )
            }

            HStack(alignment: .center, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(TVShellStyle.secondary)

                    Text("\(totalJobCount)")
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .foregroundColor(TVShellStyle.primary)

                    Text(platformShellString("Downloads"))
                        .font(.headline.weight(.semibold))
                        .foregroundColor(TVShellStyle.secondary)
                }
                .frame(width: 210, alignment: .leading)

                if activeTaskCount > 0 {
                    ProgressView(value: activeProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: TVShellStyle.accentSoft))

                    Text(progressText)
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                        .foregroundColor(TVShellStyle.primary)
                        .frame(width: 70, alignment: .trailing)
                } else {
                    Rectangle()
                        .fill(TVShellStyle.separator)
                        .frame(height: 3)
                        .cornerRadius(1.5)

                    Text(idleStatusText)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(TVShellStyle.secondary)
                        .frame(width: 120, alignment: .trailing)
                }
            }
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(TVShellStyle.surface.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(TVShellStyle.glassStroke, lineWidth: 1)
        )
    }
}



struct TVDownloadOverviewMetric: View {
    let title: String
    let value: String
    let systemImageName: String
    let tint: Color
    var isPrimary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: systemImageName)
                    .font(.system(size: isPrimary ? 28 : 24, weight: .heavy))
                    .foregroundColor(tint)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle()
                            .fill(tint.opacity(isPrimary ? 0.18 : 0.12))
                    )

                Text(title)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Text(value)
                .font(.system(size: isPrimary ? 44 : 38, weight: .heavy, design: .rounded))
                .foregroundColor(TVShellStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(tint.opacity(isPrimary ? 0.70 : 0.42))
                .frame(height: isPrimary ? 4 : 3)
                .cornerRadius(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(isPrimary ? 0.075 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(isPrimary ? 0.28 : 0.12), lineWidth: 1)
        )
    }
}



struct TVDownloadJobListRow: View {
    let job: DownloadJobGroup

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var iconBackgroundColor: Color {
        showsFocus ? Color.black.opacity(0.10) : Color.white.opacity(0.08)
    }

    private var progressTrackColor: Color {
        showsFocus ? Color.black.opacity(0.12) : Color.white.opacity(0.10)
    }

    private var detailText: String {
        var items = [
            job.serverName,
            "\(job.completedCount)/\(job.itemCount)",
            tvDownloadTransferText(for: job)
        ]
        if let speedText = tvDownloadSpeedText(for: job) {
            items.append(speedText)
        }
        if let etaText = tvDownloadEstimatedRemainingText(for: job) {
            items.append(etaText)
        }
        return items.filter { !$0.isEmpty }.joined(separator: "  •  ")
    }

    private var statusDetailText: String? {
        if let failureText = tvDownloadFailureText(for: job) {
            return failureText
        }
        if job.bucket == .completed, let locationText = tvDownloadLocationText(for: job) {
            return locationText
        }
        return nil
    }

    private var trailingText: String {
        switch job.primaryStatus {
        case .completed, .failed, .canceled:
            return job.primaryStatus.tvLocalizedTitle
        case .paused where job.completedCount == 0:
            return job.primaryStatus.tvLocalizedTitle
        default:
            return "\(Int(job.aggregateProgress * 100))%"
        }
    }

    private var trailingFontSize: CGFloat {
        trailingText.contains("%") ? 34 : 25
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle()
                    .fill(iconBackgroundColor)

                Image(systemName: job.sourceType.tvSystemImageName)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundColor(job.primaryStatus.tvTintColor)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(job.title)
                        .font(.system(size: 29, weight: .heavy))
                        .foregroundColor(primaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)

                    TVDownloadStatusBadge(status: job.primaryStatus)
                }

                Text(detailText)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let statusDetailText {
                    Text(statusDetailText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(job.bucket == .failed ? job.primaryStatus.tvTintColor : secondaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                ProgressView(value: job.aggregateProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: job.primaryStatus.tvTintColor))
                    .background(progressTrackColor)
                    .cornerRadius(2)
            }

            Text(trailingText)
                .font(.system(size: trailingFontSize, weight: .heavy, design: trailingText.contains("%") ? .monospaced : .rounded))
                .foregroundColor(primaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .frame(width: 150, alignment: .trailing)
        }
        .tvInteractiveRowPanel()
    }
}



struct TVDownloadJobListSection: View {
    let title: String
    let jobs: [DownloadJobGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 34, weight: .heavy))
                .foregroundColor(TVShellStyle.primary)

            LazyVStack(spacing: 14) {
                ForEach(jobs) { job in
                    NavigationLink(destination: TVDownloadJobDetailView(jobId: job.id)) {
                        TVDownloadJobListRow(job: job)
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }
        }
        .tvFocusSectionIfAvailable()
    }
}



struct TVDownloadJobDetailView: View {
    let jobId: UUID

    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @State private var pendingAction: TVDownloadPendingDestructiveAction?
    private let playbackCoordinator = TVPlaybackCoordinator.shared

    private var job: DownloadJobGroup? {
        downloadCenter.jobs.first(where: { $0.id == jobId })
    }

    private var playableDownloadedFiles: [VideoFile] {
        guard let job, job.bucket == .completed else { return [] }
        return tvDownloadedLocalFiles(from: job.tasks)
            .filter { $0.type == .video || $0.type == .audio }
    }

    private var currentServer: ServerConfig? {
        guard let job else { return nil }
        return networkService.servers.first(where: { $0.id == job.serverId })
    }

    var body: some View {
        TVPageScrollView(
            title: job?.title ?? platformShellString("Downloads"),
            subtitle: job?.serverName ?? platformShellString("Downloads"),
            handlesExitCommand: true,
            showsTitle: false,
            topPadding: 34
        ) {
            if let job {
                HStack(alignment: .center, spacing: 22) {
                    Text(platformShellString("Manage"))
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundColor(TVShellStyle.primary)

                    TVDownloadJobDetailActions(
                        job: job,
                        onPause: { downloadCenter.pause(jobId: job.id) },
                        onResume: { downloadCenter.resume(jobId: job.id) },
                        onRetry: { downloadCenter.retry(jobId: job.id) },
                        canPlayDownloadedFiles: !playableDownloadedFiles.isEmpty,
                        onPlayDownloadedFiles: playDownloadedFiles,
                        onCancel: { queueJobAction(job, kind: .cancelDownloads) },
                        onDeleteFiles: { queueJobAction(job, kind: .deleteFiles) },
                        onDeleteRecords: { queueJobAction(job, kind: .deleteRecords) }
                    )

                    Spacer(minLength: 0)
                }
                .tvFocusSectionIfAvailable()

                TVDownloadJobHero(job: job)

                if job.isExpandable {
                    TVDownloadTaskListSection(
                        title: platformShellString("Files in This Download"),
                        subtitle: String(format: platformShellString("%d Items"), job.itemCount),
                        tasks: job.tasks,
                        rowContextMenu: { task in
                            taskContextMenu(for: task)
                        }
                    )
                }
            } else {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Empty Downloads Title"),
                    message: platformShellString("Platform Shell TV Empty Downloads Body"),
                    systemImageName: "arrow.down.circle"
                )
            }
        }
        .navigationTitle(Text(job?.title ?? platformShellString("Downloads")))
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(title(for: action)),
                message: Text(action.message),
                primaryButton: .destructive(Text(confirmTitle(for: action))) {
                    confirm(action)
                },
                secondaryButton: .cancel(Text(platformShellString("Cancel")))
            )
        }
    }

    private func playDownloadedFiles() {
        guard let firstFile = playableDownloadedFiles.first else { return }
        let playlist = playableDownloadedFiles.count > 1 ? playableDownloadedFiles : nil
        playbackCoordinator.play(file: firstFile, playlist: playlist)
    }

    @ViewBuilder
    private func taskContextMenu(for task: DownloadTaskItem) -> some View {
        TVDownloadTaskContextMenuContent(
            snapshot: TVDownloadTaskMenuSnapshot(task: task),
            pause: {
                downloadCenter.pause(task.id)
            },
            resume: {
                downloadCenter.resume(task.id)
            },
            retry: {
                downloadCenter.retry(task.id)
            },
            cancel: {
                queueTaskAction(task, kind: .cancelDownloads)
            },
            deleteFile: {
                queueTaskAction(task, kind: .deleteFiles)
            },
            deleteRecord: {
                queueTaskAction(task, kind: .deleteRecords)
            }
        )
        .equatable()
    }

    private func queueJobAction(_ job: DownloadJobGroup, kind: TVDownloadDestructiveKind) {
        let recordCount: Int
        switch kind {
        case .cancelDownloads:
            recordCount = max(job.tasks.filter(\.isActive).count, 1)
        case .deleteFiles, .deleteRecords:
            recordCount = max(job.itemCount, 1)
        }

        pendingAction = TVDownloadPendingDestructiveAction(
            kind: kind,
            recordCount: recordCount,
            message: message(for: kind, scopeTitle: job.title),
            sectionDate: nil,
            statuses: nil,
            jobId: job.id
        )
    }

    private func queueTaskAction(_ task: DownloadTaskItem, kind: TVDownloadDestructiveKind) {
        pendingAction = TVDownloadPendingDestructiveAction(
            kind: kind,
            recordCount: 1,
            message: message(for: kind, scopeTitle: task.displayTitle),
            sectionDate: nil,
            statuses: nil,
            jobId: nil,
            taskId: task.id
        )
    }

    private func confirm(_ action: TVDownloadPendingDestructiveAction) {
        defer { pendingAction = nil }

        switch action.kind {
        case .cancelDownloads:
            if let taskId = action.taskId {
                downloadCenter.cancel(taskId)
            } else if let jobId = action.jobId {
                downloadCenter.cancel(jobId: jobId)
            }
        case .deleteFiles:
            if let taskId = action.taskId {
                downloadCenter.removeRecord(taskId, deleteLocalFile: true)
            } else if let jobId = action.jobId {
                downloadCenter.removeJob(jobId, deleteLocalFile: true)
            }
        case .deleteRecords:
            if let taskId = action.taskId {
                downloadCenter.removeRecord(taskId, deleteLocalFile: false)
            } else if let jobId = action.jobId {
                downloadCenter.removeJob(jobId, deleteLocalFile: false)
            }
        }
    }

    private func title(for action: TVDownloadPendingDestructiveAction) -> String {
        switch action.kind {
        case .cancelDownloads:
            return platformShellString(action.recordCount <= 1 ? "Cancel Download" : "Cancel Downloads")
        case .deleteFiles:
            return platformShellString(action.recordCount <= 1 ? "Delete File" : "Delete Files")
        case .deleteRecords:
            return platformShellString(action.recordCount <= 1 ? "Delete Record" : "Delete Records")
        }
    }

    private func confirmTitle(for action: TVDownloadPendingDestructiveAction) -> String {
        switch action.kind {
        case .cancelDownloads:
            return platformShellString(action.recordCount <= 1 ? "Cancel Download" : "Cancel Downloads")
        case .deleteFiles, .deleteRecords:
            return platformShellString("Delete")
        }
    }

    private func message(for kind: TVDownloadDestructiveKind, scopeTitle: String) -> String {
        switch kind {
        case .cancelDownloads:
            return String(format: platformShellString("Platform Shell TV Cancel Downloads Confirm Format"), scopeTitle)
        case .deleteFiles:
            return String(format: platformShellString("Platform Shell TV Delete Download Files Confirm Format"), scopeTitle)
        case .deleteRecords:
            return String(format: platformShellString("Platform Shell TV Delete Download Records Confirm Format"), scopeTitle)
        }
    }
}



struct TVDownloadJobDetailActions: View {
    let job: DownloadJobGroup
    let onPause: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let canPlayDownloadedFiles: Bool
    let onPlayDownloadedFiles: () -> Void
    let onCancel: () -> Void
    let onDeleteFiles: () -> Void
    let onDeleteRecords: () -> Void

    @State private var focusedHeaderAction: TVHeaderActionFocus?

    private var hasActions: Bool {
        job.activeCount > 0
            || job.pausedCount > 0
            || job.failedCount > 0
            || job.canceledCount > 0
            || canPlayDownloadedFiles
            || job.bucket == .completed
    }

    var body: some View {
        if hasActions {
            HStack(spacing: 16) {
                if job.downloadingCount > 0 || job.queuedCount > 0 {
                    Button(action: onPause) {
                        TVHeaderIconActionButton(
                            title: platformShellString("Pause All"),
                            systemImageName: "pause.fill",
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "pause", title: title, isFocused: isFocused, isDestructive: false)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                if job.pausedCount > 0 {
                    Button(action: onResume) {
                        TVHeaderIconActionButton(
                            title: platformShellString("Resume All"),
                            systemImageName: "play.fill",
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "resume", title: title, isFocused: isFocused, isDestructive: false)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                if job.failedCount > 0 || job.canceledCount > 0 {
                    Button(action: onRetry) {
                        TVHeaderIconActionButton(
                            title: platformShellString("Retry Download"),
                            systemImageName: "arrow.clockwise",
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "retry", title: title, isFocused: isFocused, isDestructive: false)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                if canPlayDownloadedFiles {
                    Button(action: onPlayDownloadedFiles) {
                        TVHeaderIconActionButton(
                            title: platformShellString("Play"),
                            systemImageName: "play.fill",
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "play", title: title, isFocused: isFocused, isDestructive: false)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                if job.activeCount > 0 {
                    Button(action: onCancel) {
                        TVHeaderIconActionButton(
                            title: platformShellString("Cancel Active Downloads"),
                            systemImageName: "xmark.circle",
                            isDestructive: true,
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "cancel", title: title, isFocused: isFocused, isDestructive: true)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                if job.bucket == .completed || job.bucket == .failed {
                    let deleteFilesTitle = platformShellString(job.itemCount > 1 ? "Delete Files" : "Delete File")
                    Button(action: onDeleteFiles) {
                        TVHeaderIconActionButton(
                            title: deleteFilesTitle,
                            systemImageName: "trash",
                            isDestructive: true,
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "delete-files", title: title, isFocused: isFocused, isDestructive: true)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()

                    let deleteRecordsTitle = platformShellString(job.itemCount > 1 ? "Delete Records" : "Delete Record")
                    Button(action: onDeleteRecords) {
                        TVHeaderIconActionButton(
                            title: deleteRecordsTitle,
                            systemImageName: "minus.circle",
                            isDestructive: true,
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "delete-records", title: title, isFocused: isFocused, isDestructive: true)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                TVHeaderActionDescriptionText(
                    text: focusedHeaderAction?.title,
                    width: 340,
                    isDestructive: focusedHeaderAction?.isDestructive ?? false
                )
            }
            .tvFocusSectionIfAvailable()
        }
    }

    private func updateFocus(id: String, title: String, isFocused: Bool, isDestructive: Bool) {
        if isFocused {
            focusedHeaderAction = TVHeaderActionFocus(id: id, title: title, isDestructive: isDestructive)
        } else if focusedHeaderAction?.id == id {
            focusedHeaderAction = nil
        }
    }
}



struct TVDownloadJobInfoSection: View {
    let job: DownloadJobGroup

    private var bytesDownloaded: Int64 {
        job.tasks.reduce(Int64(0)) { $0 + max($1.bytesDownloaded, 0) }
    }

    private var bytesTotal: Int64 {
        job.tasks.reduce(Int64(0)) { $0 + max($1.bytesTotal, 0) }
    }

    private var sizeText: String? {
        if bytesTotal > 0 {
            if job.bucket == .completed {
                return tvByteCountString(bytesTotal)
            }
            return "\(tvByteCountString(bytesDownloaded)) / \(tvByteCountString(bytesTotal))"
        }
        if bytesDownloaded > 0 {
            return tvByteCountString(bytesDownloaded)
        }
        return nil
    }

    private var completedText: String {
        "\(job.completedCount)/\(job.itemCount)"
    }

    private var capabilityText: String {
        "\(backgroundCapabilityText)  •  \(resumeCapabilityText)"
    }

    private var backgroundCapabilityText: String {
        if job.tasks.contains(where: { $0.backgroundCapability == .foregroundOnly }) {
            return platformShellString("Foreground only")
        }
        if job.tasks.allSatisfy({ $0.backgroundCapability == .backgroundTransfer }) {
            return platformShellString("Background capable")
        }
        return platformShellString("Background varies")
    }

    private var resumeCapabilityText: String {
        if job.tasks.contains(where: { $0.resumeCapability == .restartOnly }) {
            return platformShellString("Restarts on resume")
        }
        if job.tasks.allSatisfy({ $0.resumeCapability == .resumable }) {
            return platformShellString("Can resume")
        }
        return platformShellString("Resume varies")
    }

    private var detailItems: [TVDownloadInfoItem] {
        var items: [TVDownloadInfoItem] = [
            TVDownloadInfoItem(
                title: platformShellString("Server"),
                value: job.serverName,
                systemImageName: "server.rack",
                tint: TVShellStyle.accentSoft
            ),
            TVDownloadInfoItem(
                title: platformShellString("Server Type"),
                value: job.sourceType.tvDisplayName,
                systemImageName: job.sourceType.tvSystemImageName,
                tint: TVShellStyle.accentSoft
            ),
            TVDownloadInfoItem(
                title: platformShellString("Files"),
                value: "\(job.itemCount)",
                systemImageName: "doc.on.doc",
                tint: Color.white.opacity(0.82)
            ),
            TVDownloadInfoItem(
                title: platformShellString("Completed"),
                value: completedText,
                systemImageName: "checkmark.circle",
                tint: Color(red: 0.48, green: 0.88, blue: 0.62)
            ),
            TVDownloadInfoItem(
                title: platformShellString("Date Added"),
                value: tvTimestamp(job.createdAt),
                systemImageName: "calendar",
                tint: Color.white.opacity(0.82)
            ),
            TVDownloadInfoItem(
                title: platformShellString("Details"),
                value: capabilityText,
                systemImageName: "info.circle",
                tint: Color.white.opacity(0.82)
            )
        ]

        if let sizeText {
            items.insert(
                TVDownloadInfoItem(
                    title: platformShellString("Size"),
                    value: sizeText,
                    systemImageName: "externaldrive",
                    tint: Color.white.opacity(0.82)
                ),
                at: 4
            )
        }

        if let locationText = tvDownloadLocationText(for: job) {
            items.append(
                TVDownloadInfoItem(
                    title: platformShellString("Storage"),
                    value: locationText,
                    systemImageName: "folder",
                    tint: Color(red: 0.48, green: 0.88, blue: 0.62)
                )
            )
        }

        return items
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 18),
                GridItem(.flexible(), spacing: 18)
            ],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(detailItems) { item in
                TVDownloadInfoTile(item: item)
            }
        }
    }
}



struct TVDownloadInfoItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let systemImageName: String
    let tint: Color

    init(title: String, value: String, systemImageName: String, tint: Color) {
        self.id = title
        self.title = title
        self.value = value
        self.systemImageName = systemImageName
        self.tint = tint
    }
}



struct TVDownloadInfoTile: View {
    let item: TVDownloadInfoItem

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(item.tint.opacity(0.14))

                Image(systemName: item.systemImageName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(item.tint)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)

                Text(item.value)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TVShellStyle.surface.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(TVShellStyle.glassStroke, lineWidth: 1)
        )
    }
}



struct TVDownloadTaskListSection<RowMenu: View>: View {
    let title: String
    let subtitle: String?
    let tasks: [DownloadTaskItem]
    let rowContextMenu: (DownloadTaskItem) -> RowMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(TVShellStyle.secondary)
                }
            }

            LazyVStack(spacing: 14) {
                ForEach(tasks) { task in
                    TVDownloadTaskRow(task: task)
                        .contextMenu {
                            rowContextMenu(task)
                        }
                }
            }
        }
        .tvFocusSectionIfAvailable()
    }
}



struct TVDownloadJobHero: View {
    let job: DownloadJobGroup

    private var trailingText: String {
        switch job.primaryStatus {
        case .completed, .failed, .canceled:
            return job.primaryStatus.tvLocalizedTitle
        case .paused where job.completedCount == 0:
            return job.primaryStatus.tvLocalizedTitle
        default:
            return "\(Int(job.aggregateProgress * 100))%"
        }
    }

    private var trailingFontSize: CGFloat {
        trailingText.contains("%") ? 54 : 34
    }

    private var statusTint: Color {
        job.primaryStatus.tvTintColor
    }

    private var itemCountText: String {
        job.itemCount == 1
            ? platformShellString("File")
            : String(format: platformShellString("%d Items"), job.itemCount)
    }

    private var metadataText: String {
        [
            job.serverName,
            job.sourceType.tvDisplayName,
            itemCountText,
            tvTimestamp(job.createdAt)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "  •  ")
    }

    private var transferLineText: String {
        var items = [tvDownloadTransferText(for: job)]
        if let speedText = tvDownloadSpeedText(for: job) {
            items.append(speedText)
        }
        if let etaText = tvDownloadEstimatedRemainingText(for: job) {
            items.append(etaText)
        }
        return items.filter { !$0.isEmpty }.joined(separator: "  •  ")
    }

    var body: some View {
        TVFocusableStaticPanel {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(statusTint.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(statusTint.opacity(0.24), lineWidth: 1)
                            )

                        Image(systemName: job.sourceType.tvSystemImageName)
                            .font(.system(size: 36, weight: .heavy))
                            .foregroundColor(statusTint)
                    }
                    .frame(width: 68, height: 68)

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 14) {
                            Text(job.title)
                                .font(.system(size: 36, weight: .heavy))
                                .foregroundColor(TVShellStyle.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)

                            TVDownloadStatusBadge(status: job.primaryStatus)
                        }

                        Text(metadataText)
                            .font(.title3.weight(.semibold))
                            .foregroundColor(TVShellStyle.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }

                    Spacer(minLength: 18)

                    VStack(alignment: .trailing, spacing: 6) {
                        Text(trailingText)
                            .font(.system(size: trailingFontSize, weight: .heavy, design: trailingText.contains("%") ? .monospaced : .rounded))
                            .foregroundColor(TVShellStyle.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.58)

                        Text(tvDownloadTransferText(for: job))
                            .font(.headline.weight(.semibold))
                            .foregroundColor(TVShellStyle.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                    .frame(width: 290, alignment: .trailing)
                }

                ProgressView(value: job.aggregateProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: statusTint))
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(2)

                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(transferLineText)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)

                    Spacer(minLength: 12)

                    Text("\(job.completedCount)/\(job.itemCount)")
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(1)
                }

                if let failureText = tvDownloadFailureText(for: job) {
                    Text(failureText)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(Color(red: 1.0, green: 0.48, blue: 0.40))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let locationText = tvDownloadLocationText(for: job), job.bucket == .completed {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(red: 0.48, green: 0.88, blue: 0.62))

                        Text(locationText)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(TVShellStyle.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                }
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(TVShellStyle.surface.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(TVShellStyle.glassStroke, lineWidth: 1)
            )
        }
        .tvDisableSystemFocusEffect()
    }
}



struct TVDownloadHeroMetric: View {
    let title: String
    let value: String
    let systemImageName: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImageName)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
            }
        }
        .frame(width: 150, alignment: .leading)
    }
}



struct TVDownloadTaskRow: View {
    let task: DownloadTaskItem

    var body: some View {
        Button(action: {}) {
            TVDownloadTaskRowContent(task: task)
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVDownloadTaskRowContent: View {
    let task: DownloadTaskItem

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var iconBackgroundColor: Color {
        showsFocus ? Color.black.opacity(0.10) : Color.white.opacity(0.08)
    }

    private var progressTrackColor: Color {
        showsFocus ? Color.black.opacity(0.12) : Color.white.opacity(0.10)
    }

    private var trailingText: String {
        switch task.status {
        case .completed, .failed, .canceled:
            return task.status.tvLocalizedTitle
        case .paused where task.progress <= 0:
            return task.status.tvLocalizedTitle
        default:
            return "\(Int(task.progress * 100))%"
        }
    }

    private var trailingFontSize: CGFloat {
        trailingText.contains("%") ? 28 : 22
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                Circle()
                    .fill(iconBackgroundColor)

                Image(systemName: task.status.tvSystemImageName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(task.status.tvTintColor)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(task.displayTitle)
                        .font(.system(size: 25, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .foregroundColor(primaryColor)

                    TVDownloadStatusBadge(status: task.status)
                }

                ProgressView(value: task.progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: task.status.tvTintColor))
                    .background(progressTrackColor)
                    .cornerRadius(2)

                Text(taskDetailText)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(trailingText)
                .font(.system(size: trailingFontSize, weight: .heavy, design: trailingText.contains("%") ? .monospaced : .rounded))
                .foregroundColor(primaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .frame(width: 126, alignment: .trailing)
        }
        .tvInteractiveRowPanel()
    }

    private var taskDetailText: String {
        var items: [String] = []
        if task.bytesTotal > 0 {
            items.append("\(tvByteCountString(task.bytesDownloaded)) / \(tvByteCountString(task.bytesTotal))")
        } else {
            items.append(tvByteCountString(task.bytesDownloaded))
        }
        if task.status == .downloading, task.speedBytesPerSec > 0 {
            items.append("\(tvByteCountString(Int64(task.speedBytesPerSec)))/s")
        }
        return items.joined(separator: "  •  ")
    }
}



struct TVDownloadStatusBadge: View {
    let status: DownloadTaskStatus

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: status.tvSystemImageName)
                .font(.system(size: 15, weight: .bold))

            Text(status.tvLocalizedTitle)
                .font(.system(size: 16, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundColor(status.tvTintColor)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            Capsule(style: .continuous)
                .fill(status.tvTintColor.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(status.tvTintColor.opacity(0.34), lineWidth: 1)
        )
    }
}
#endif
