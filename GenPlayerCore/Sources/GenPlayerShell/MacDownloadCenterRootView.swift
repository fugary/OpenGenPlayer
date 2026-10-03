#if os(macOS)
import SwiftUI
import GenPlayerCore

private enum SectionActionKind {
    case cancelDownloads
    case deleteFiles
    case deleteRecords
}

struct MacDownloadCenterRootView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @EnvironmentObject private var tabContext: MacTabContext
    var onNavigateToSource: ((UUID, VideoFile) -> Void)? = nil
    
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var selectedSegment = 0
    @State private var expandedJobIDs = Set<UUID>()
    @State private var showDeleteFilesAlert = false
    @State private var showDeleteRecordsAlert = false
    @State private var jobToDelete: UUID?
    
    @State private var showSectionAlert = false
    @State private var sectionActionKind: SectionActionKind = .deleteRecords
    @State private var sectionActionDate: Date?

    private struct JobSection: Identifiable {
        let date: Date
        let jobs: [DownloadJobGroup]
        var id: Date { date }
    }

    private var displayedJobs: [DownloadJobGroup] {
        switch selectedSegment {
        case 0: return downloadCenter.activeJobs
        case 1: return downloadCenter.completedJobs
        default: return downloadCenter.failedJobs
        }
    }

    private var displayedSections: [JobSection] {
        let grouped = Dictionary(grouping: displayedJobs) { job in
            Calendar.current.startOfDay(for: job.createdAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            JobSection(date: day, jobs: grouped[day]?.sorted(by: { $0.createdAt > $1.createdAt }) ?? [])
        }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }

    private var totalSpeedString: String {
        let totalSpeed = downloadCenter.activeJobs.reduce(0.0) { $0 + $1.speedBytesPerSec }
        guard totalSpeed > 0 else { return "-- MB/s" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(totalSpeed), countStyle: .file))/s"
    }
    
    private var totalEtaString: String? {
        let activeJobs = downloadCenter.activeJobs
        guard !activeJobs.isEmpty else { return nil }
        
        var totalRemainingBytes: Int64 = 0
        var totalSpeed: Double = 0
        
        for job in activeJobs {
            if job.primaryStatus == .downloading {
                totalRemainingBytes += (job.totalBytes - job.downloadedBytes)
                totalSpeed += job.speedBytesPerSec
            }
        }
        
        if totalSpeed > 0 && totalRemainingBytes > 0 {
            let etaSeconds = Double(totalRemainingBytes) / totalSpeed
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            return formatter.string(from: etaSeconds)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MacPageHeaderView(title: platformShellString("Download Center"))
                Spacer()
                if !downloadCenter.activeJobs.isEmpty && selectedSegment == 0 {
                    HStack(spacing: 16) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(totalSpeedString)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                            if let eta = totalEtaString {
                                Text("\(platformShellString("ETA:")) \(eta)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 16)
            
            Picker("", selection: $selectedSegment) {
                Text("\(platformShellString("In Progress")) (\(downloadCenter.activeJobs.count))").tag(0)
                Text("\(platformShellString("Completed")) (\(downloadCenter.completedJobs.count))").tag(1)
                Text("\(platformShellString("Failed")) (\(downloadCenter.failedJobs.count))").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: 600)

            if displayedJobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(platformShellString("No download tasks"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(displayedSections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Text(dateFormatter.string(from: section.date))
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    
                                    Spacer()
                                    
                                    HStack(spacing: 8) {
                                        if selectedSegment == 0 {
                                            MacHoverTextButton(
                                                title: platformShellString("Cancel All Downloads"),
                                                iconName: "xmark.circle",
                                                destructive: true
                                            ) {
                                                queueSectionAction(date: section.date, kind: .cancelDownloads)
                                            }
                                        } else if selectedSegment == 1 {
                                            MacHoverTextButton(
                                                title: platformShellString("Delete All Files"),
                                                iconName: "trash",
                                                destructive: true
                                            ) {
                                                queueSectionAction(date: section.date, kind: .deleteFiles)
                                            }
                                            MacHoverTextButton(
                                                title: platformShellString("Delete All Records"),
                                                iconName: "minus.circle",
                                                destructive: true
                                            ) {
                                                queueSectionAction(date: section.date, kind: .deleteRecords)
                                            }
                                        } else {
                                            MacHoverTextButton(
                                                title: platformShellString("Delete All Records"),
                                                iconName: "minus.circle",
                                                destructive: true
                                            ) {
                                                queueSectionAction(date: section.date, kind: .deleteRecords)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 8)

                                ForEach(section.jobs) { job in
                                    MacDownloadJobCard(
                                        job: job,
                                        isExpanded: Binding(
                                            get: { expandedJobIDs.contains(job.id) },
                                            set: { isExp in
                                                if isExp { expandedJobIDs.insert(job.id) }
                                                else { expandedJobIDs.remove(job.id) }
                                            }
                                        ),
                                        onDeleteFiles: {
                                            jobToDelete = job.id
                                            showDeleteFilesAlert = true
                                        },
                                        onDeleteRecords: {
                                            jobToDelete = job.id
                                            showDeleteRecordsAlert = true
                                        },
                                        onNavigateToSource: onNavigateToSource
                                    )
                                    .padding(.horizontal, 24)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(isPresented: $showDeleteFilesAlert) {
            Alert(
                title: Text(platformShellString("Delete Files")),
                message: Text(platformShellString("Are you sure you want to delete these downloaded files?")),
                primaryButton: .destructive(Text(platformShellString("Delete"))) {
                    if let jobId = jobToDelete {
                        downloadCenter.removeJob(jobId, deleteLocalFile: true)
                    }
                },
                secondaryButton: .cancel(Text(platformShellString("Cancel")))
            )
        }
        .background(
            Color.clear
                .alert(isPresented: $showDeleteRecordsAlert) {
                    Alert(
                        title: Text(platformShellString("Delete Records")),
                        message: Text(platformShellString("Are you sure you want to delete these download records? Files will be kept.")),
                        primaryButton: .destructive(Text(platformShellString("Delete"))) {
                            if let jobId = jobToDelete {
                                downloadCenter.removeJob(jobId, deleteLocalFile: false)
                            }
                        },
                        secondaryButton: .cancel(Text(platformShellString("Cancel")))
                    )
                }
        )
        .background(
            Color.clear
                .alert(isPresented: $showSectionAlert) {
                    Alert(
                        title: Text(sectionAlertTitle()),
                        message: Text(sectionAlertMessage()),
                        primaryButton: .destructive(Text(platformShellString("Confirm"))) {
                            performSectionAction()
                        },
                        secondaryButton: .cancel(Text(platformShellString("Cancel")))
                    )
                }
        )
        .onAppear {
            if displayedJobs.isEmpty {
                if !downloadCenter.activeJobs.isEmpty {
                    selectedSegment = 0
                } else if !downloadCenter.completedJobs.isEmpty {
                    selectedSegment = 1
                } else if !downloadCenter.failedJobs.isEmpty {
                    selectedSegment = 2
                }
            }
        }
        .id("MacDownloadCenterRootView_\(appLanguage)")
    }

    private func queueSectionAction(date: Date, kind: SectionActionKind) {
        self.sectionActionDate = date
        self.sectionActionKind = kind
        self.showSectionAlert = true
    }

    private func sectionAlertTitle() -> String {
        switch sectionActionKind {
        case .cancelDownloads: return platformShellString("Cancel Downloads")
        case .deleteFiles: return platformShellString("Delete Files")
        case .deleteRecords: return platformShellString("Delete Records")
        }
    }

    private func sectionAlertMessage() -> String {
        switch sectionActionKind {
        case .cancelDownloads: return platformShellString("Are you sure you want to cancel all in-progress downloads from this date?")
        case .deleteFiles: return platformShellString("Are you sure you want to delete all downloaded files from this date?")
        case .deleteRecords: return platformShellString("Are you sure you want to delete all download records from this date?")
        }
    }

    private func performSectionAction() {
        guard let date = sectionActionDate else { return }
        switch sectionActionKind {
        case .cancelDownloads:
            downloadCenter.cancelRecords(createdOn: date, statuses: [.queued, .downloading, .paused])
        case .deleteFiles:
            downloadCenter.removeRecords(createdOn: date, statuses: [.completed], deleteLocalFiles: true)
        case .deleteRecords:
            if selectedSegment == 1 {
                downloadCenter.removeRecords(createdOn: date, statuses: [.completed], deleteLocalFiles: false)
            } else {
                downloadCenter.removeRecords(createdOn: date, statuses: [.failed, .canceled], deleteLocalFiles: false)
            }
        }
    }
}

struct MacHoverIconButton: View {
    let iconName: String
    let tooltip: String
    let destructive: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        if #available(macOS 26.0, *) {
            MacToolbarButton(
                systemImage: iconName,
                title: tooltip,
                role: destructive ? .destructive : nil,
                diameter: 28,
                symbolSize: 16,
                symbolWeight: .regular,
                action: action
            )
        } else {
            legacyButton
        }
    }

    private var legacyButton: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundColor(isHovered ? (destructive ? .red : .primary) : .secondary)
                .frame(width: 28, height: 28)
                .background(isHovered ? (destructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.08)) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered = $0 }
        .macPointerHover()
    }
}

struct MacHoverTextButton: View {
    let title: String
    let iconName: String
    let destructive: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isHovered ? (destructive ? .red : .primary) : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? (destructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.08)) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .macPointerHover()
    }
}

struct MacDownloadJobCard: View {
    @EnvironmentObject private var tabContext: MacTabContext
    let job: DownloadJobGroup
    @Binding var isExpanded: Bool
    let onDeleteFiles: () -> Void
    let onDeleteRecords: () -> Void
    var onNavigateToSource: ((UUID, VideoFile) -> Void)? = nil
    
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var isHovered = false
    
    private var serverConfig: ServerConfig? {
        AppNetworkService.shared.servers.first { $0.id == job.serverId }
    }
    
    private var posterURL: URL? {
        guard let server = serverConfig,
              let firstTask = job.tasks.first,
              let remoteItemId = firstTask.remoteItemId,
              !remoteItemId.isEmpty else {
            return nil
        }
        
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch server.type {
        case .jellyfin, .emby:
            return URL(string: "\(baseURL)/Items/\(remoteItemId)/Images/Primary?maxHeight=200&maxWidth=200&quality=90")
        case .plex:
            guard let token = server.accessToken else { return nil }
            var comps = URLComponents(string: "\(baseURL)/photo/:/transcode")
            comps?.queryItems = [
                URLQueryItem(name: "url", value: remoteItemId),
                URLQueryItem(name: "width", value: "200"),
                URLQueryItem(name: "height", value: "200"),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ]
            return comps?.url
        default:
            return nil
        }
    }

    private var jobEtaString: String? {
        if job.primaryStatus == .downloading {
            let speed = job.speedBytesPerSec
            let remainingBytes = job.totalBytes - job.downloadedBytes
            if speed > 0 && remainingBytes > 0 {
                let etaSeconds = Double(remainingBytes) / speed
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.hour, .minute, .second]
                formatter.unitsStyle = .abbreviated
                return formatter.string(from: etaSeconds)
            }
        }
        return nil
    }
    
    private func hasNavigationTarget(for job: DownloadJobGroup) -> Bool {
        guard let firstTask = job.tasks.first else { return false }
        let serverId = job.serverId
        return AppNetworkService.shared.savedServers.contains(where: { $0.id == serverId })
    }
    
    private func navigateToSource(for job: DownloadJobGroup) {
        guard let firstTask = job.tasks.first else { return }
        let serverId = job.serverId
        
        // Find if server exists
        guard let server = AppNetworkService.shared.savedServers.first(where: { $0.id == serverId }) else { return }
        
        // Construct VideoFile representing the source
        let targetItemId: String
        if let seriesId = firstTask.seriesId, !seriesId.isEmpty {
            targetItemId = seriesId
        } else {
            targetItemId = firstTask.remoteItemId ?? firstTask.id.uuidString
        }
        
        var targetFile = VideoFile(
            name: job.title,
            url: URL(string: firstTask.remotePath) ?? URL(fileURLWithPath: firstTask.remotePath),
            type: firstTask.jobKind == .seasonPack ? .folder : .video,
            size: firstTask.bytesTotal,
            date: firstTask.createdAt,
            isRemote: true
        )
        targetFile.jellyfinServerId = job.serverId.uuidString
        targetFile.jellyfinItemId = targetItemId
        
        // Navigate
        onNavigateToSource?(serverId, targetFile)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Icon / Thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 80, height: 48)
                    
                    if let url = posterURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                Image(systemName: "film")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 20))
                            }
                        }
                    } else {
                        Image(systemName: job.sourceType == .smb || job.sourceType == .webdav || job.sourceType == .alist ? "folder.fill" : "doc.text.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 24))
                    }
                }
                .frame(width: 80, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.groupTitle ?? job.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if job.bucket == .active {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 6)
                                Capsule()
                                    .fill(statusColor(for: job))
                                    .frame(width: geo.size.width * CGFloat(max(0, min(1, job.aggregateProgress))), height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                    
                    HStack(spacing: 8) {
                        Text(statusText(for: job))
                            .font(.system(size: 12))
                            .foregroundColor(statusColor(for: job))
                        
                        if job.bucket == .active {
                            if job.totalBytes > 0 {
                                Text("•")
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("\(ByteCountFormatter.string(fromByteCount: job.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            if job.primaryStatus == .downloading {
                                let speed = job.speedBytesPerSec
                                if speed > 0 {
                                    Text("•")
                                        .foregroundColor(.secondary.opacity(0.5))
                                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    
                                    if let eta = jobEtaString {
                                        Text("•")
                                            .foregroundColor(.secondary.opacity(0.5))
                                        Text("\(platformShellString("ETA:")) \(eta)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    if job.bucket == .active {
                        MacHoverIconButton(
                            iconName: job.primaryStatus == .paused ? "play.circle.fill" : "pause.circle.fill",
                            tooltip: platformShellString(job.primaryStatus == .paused ? "Resume" : "Pause"),
                            destructive: false
                        ) {
                            if job.primaryStatus == .paused {
                                downloadCenter.resume(jobId: job.id)
                            } else {
                                downloadCenter.pause(jobId: job.id)
                            }
                        }
                        
                        MacHoverIconButton(
                            iconName: "xmark.circle.fill",
                            tooltip: platformShellString("Cancel"),
                            destructive: true
                        ) {
                            downloadCenter.cancel(jobId: job.id)
                        }
                    } else if job.bucket == .failed {
                        MacHoverIconButton(
                            iconName: "arrow.clockwise.circle.fill",
                            tooltip: platformShellString("Retry"),
                            destructive: false
                        ) {
                            downloadCenter.retry(jobId: job.id)
                        }
                    }
                    
                    if hasNavigationTarget(for: job) {
                        MacHoverIconButton(
                            iconName: "info.circle",
                            tooltip: platformShellString("View Details"),
                            destructive: false
                        ) {
                            navigateToSource(for: job)
                        }
                    }

                    if let fileURL = downloadedFileURL(for: job) {
                        MacHoverIconButton(
                            iconName: "folder",
                            tooltip: platformShellString("Show in Finder"),
                            destructive: false
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                    }
                    
                    if job.bucket == .completed {
                        MacHoverIconButton(
                            iconName: "trash",
                            tooltip: platformShellString("Delete Files"),
                            destructive: true,
                            action: onDeleteFiles
                        )
                    }
                    
                    MacHoverIconButton(
                        iconName: "minus.circle",
                        tooltip: platformShellString("Delete Record"),
                        destructive: true,
                        action: onDeleteRecords
                    )
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(isHovered ? 0.3 : 0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.05 : 0.0), radius: 5, x: 0, y: 2)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
        }
    }
    
    private func statusText(for job: DownloadJobGroup) -> String {
        switch job.primaryStatus {
        case .queued: return platformShellString("Queued")
        case .downloading: return platformShellString("Downloading")
        case .paused: return platformShellString("Paused")
        case .completed: return platformShellString("Completed")
        case .failed: return platformShellString("Failed")
        case .canceled: return platformShellString("Canceled")
        }
    }
    
    private func statusColor(for job: DownloadJobGroup) -> Color {
        switch job.primaryStatus {
        case .downloading: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused, .queued, .canceled: return .secondary
        }
    }
    
    private func downloadedFileURL(for job: DownloadJobGroup) -> URL? {
        if job.bucket == .active { return nil }
        guard let firstTask = job.tasks.first else { return nil }
        guard let path = firstTask.localFilePath, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
#endif
