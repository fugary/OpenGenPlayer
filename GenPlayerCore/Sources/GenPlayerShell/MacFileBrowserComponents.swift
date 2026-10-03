#if os(macOS)
import SwiftUI
import GenPlayerCore

public struct MacFileGridItemCard: View {
    let file: VideoFile
    let server: ServerConfig?
    let markers: [String]
    let siblingFiles: [VideoFile]?
    @State private var isHovered = false
    @ObservedObject private var historyService = HistoryService.shared

    public init(file: VideoFile, server: ServerConfig? = nil, markers: [String] = [], siblingFiles: [VideoFile]? = nil) {
        self.file = file
        self.server = server
        self.markers = markers
        self.siblingFiles = siblingFiles
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(file.type == .folder ? Color.secondary.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Group {
                                if file.type != .folder {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                }
                            }
                        )
                    
                    MacRemoteFileImage(file: file, server: server, siblingFiles: siblingFiles)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                    if file.showsMacPreviewIndicatorBadge {
                        MacMediaIndicatorBadge(
                            file: file,
                            playbackSnapshot: playbackProgressSnapshot,
                            diameter: 16
                        )
                        .offset(x: 6, y: 6)
                    }
                }
                .frame(width: 80, height: 80)
                
                if !markers.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(markers, id: \.self) { marker in
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.72))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                    )

                                Image(systemName: marker)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(marker == "star.fill" ? .yellow : .white)
                            }
                            .frame(width: 18, height: 18)
                        }
                    }
                    .padding(4)
                }
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
            .zIndex(isHovered ? 1 : 0)

            VStack(alignment: .center, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(isHovered ? .accentColor : .primary)

                if file.type != .folder {
                    Text(formatFileSize(file.size))
                        .font(.system(size: 11))
                        .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary)
                        .lineLimit(1)
                } else if let count = file.itemCount {
                    Text(String(format: NSLocalizedString("%d items", comment: ""), count))
                        .font(.system(size: 11))
                        .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 36, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .macPointerHover()
    }

    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        guard file.type == .video || file.type == .audio else {
            return nil
        }
        return historyService.playbackProgressSnapshot(matching: file)
    }
}

public struct MacFileListItem: View {
    let file: VideoFile
    let server: ServerConfig?
    let markers: [String]
    let siblingFiles: [VideoFile]?
    @State private var isHovered = false
    @ObservedObject private var historyService = HistoryService.shared

    public init(file: VideoFile, server: ServerConfig? = nil, markers: [String] = [], siblingFiles: [VideoFile]? = nil) {
        self.file = file
        self.server = server
        self.markers = markers
        self.siblingFiles = siblingFiles
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(file.type == .folder ? Color.secondary.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Group {
                                if file.type != .folder {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                }
                            }
                        )
                    MacRemoteFileImage(file: file, server: server, siblingFiles: siblingFiles)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        
                    if file.showsMacPreviewIndicatorBadge {
                        MacMediaIndicatorBadge(
                            file: file,
                            playbackSnapshot: playbackProgressSnapshot,
                            diameter: 10
                        )
                        .offset(x: 4, y: 4)
                    }
                }
                .frame(width: 32, height: 32)
                
                if !markers.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(markers, id: \.self) { marker in
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.72))
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                    )

                                Image(systemName: marker)
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(marker == "star.fill" ? .yellow : .white)
                            }
                            .frame(width: 14, height: 14)
                        }
                    }
                    .padding(2)
                    .offset(x: 4, y: -4)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? .accentColor : .primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(formatDate(file.date))
                        .font(.system(size: 11))
                        .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary)
                    
                    if file.type != .folder {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(formatFileSize(file.size))
                            .font(.system(size: 11))
                            .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary)
                    } else if let count = file.itemCount {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(String(format: NSLocalizedString("%d items", comment: ""), count))
                            .font(.system(size: 11))
                            .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .macPointerHover()
    }

    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        guard file.type == .video || file.type == .audio else {
            return nil
        }
        return historyService.playbackProgressSnapshot(matching: file)
    }
}

public struct MacBreadcrumbButton<Label: View>: View {
    let action: () -> Void
    let isCurrent: Bool
    let label: () -> Label
    @State private var isHovered = false

    public init(action: @escaping () -> Void, isCurrent: Bool = false, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.isCurrent = isCurrent
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label()
                .foregroundColor(isHovered ? .accentColor : (isCurrent ? .primary : .secondary))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .macPointerHover()
    }
}
#endif

