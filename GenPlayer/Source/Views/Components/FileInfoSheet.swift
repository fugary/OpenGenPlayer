import SwiftUI

struct FileInfoSheet: View {
    let file: VideoFile
    var serverName: String? = nil
    var onShowInFolder: (() -> Void)? = nil
    
    @Environment(\.presentationMode) private var presentationMode
    @State private var toastMessage: String? = nil
    
    private var formattedPath: String {
        if let serverPath = file.serverPath, !serverPath.isEmpty {
            return serverPath
        }
        return file.url.path
    }
    
    private var streamURLString: String? {
        if file.isRemote {
            if let serverId = file.jellyfinServerId,
               let itemId = file.jellyfinItemId,
               let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString == serverId }) {
                let token = server.accessToken ?? ""
                if server.type == .jellyfin {
                    if let resolved = JellyfinService.shared.resolvePlaybackURL(server: server, itemId: itemId, token: token) ?? JellyfinService.shared.getStreamURL(server: server, itemId: itemId, token: token) {
                        return resolved.absoluteString
                    }
                } else if server.type == .emby {
                    if let resolved = EmbyService.shared.resolvePlaybackURL(server: server, itemId: itemId, token: token) ?? EmbyService.shared.getStreamURL(server: server, itemId: itemId, token: token) {
                        return resolved.absoluteString
                    }
                }
            }
            if !file.url.isFileURL {
                return file.url.absoluteString
            }
        }
        return nil
    }
    
    private var formattedSize: String {
        guard file.size > 0 else {
            return NSLocalizedString("Unknown Size", comment: "")
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: file.size)
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: file.date)
    }
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text(NSLocalizedString("Basic Info", comment: ""))) {
                    HStack(alignment: .top) {
                        Text(NSLocalizedString("File Name", comment: ""))
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(file.name)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.leading)
                    }
                    
                    HStack {
                        Text(NSLocalizedString("File Size", comment: ""))
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(formattedSize)
                    }
                    
                    HStack {
                        Text(NSLocalizedString("File Type", comment: ""))
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(file.url.pathExtension.uppercased())
                    }
                    
                    if let serverName = serverName {
                        HStack {
                            Text(NSLocalizedString("Source", comment: ""))
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Text(serverName)
                        }
                    }
                    
                    HStack {
                        Text(NSLocalizedString("Modified Date", comment: ""))
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(formattedDate)
                    }
                }
                
                Section(header: Text(NSLocalizedString("File Path", comment: ""))) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(formattedPath)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        
                        HStack {
                            Spacer()
                            Button(action: {
                                copyPathToClipboard(formattedPath)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                    Text(NSLocalizedString("Copy Path", comment: ""))
                                }
                                .font(.subheadline)
                                .foregroundColor(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())

                        }
                    }
                    .padding(.vertical, 4)
                }
                
                if let streamURL = streamURLString {
                    Section(header: Text(NSLocalizedString("Stream URL", comment: ""))) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(streamURL)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                            
                            HStack {
                                Spacer()
                                Button(action: {
                                    copyPathToClipboard(streamURL, message: NSLocalizedString("Stream URL Copied to Clipboard", comment: ""))
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "link")
                                        Text(NSLocalizedString("Copy Stream URL", comment: ""))
                                    }
                                    .font(.subheadline)
                                    .foregroundColor(Color.accentColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                if let onShowInFolder = onShowInFolder {
                    Section {
                        Button(action: {
                            presentationMode.wrappedValue.dismiss()
                            onShowInFolder()
                        }) {
                            HStack {
                                Image(systemName: "folder")
                                Text(NSLocalizedString("Show in Folder", comment: ""))
                            }
                            .foregroundColor(Color.accentColor)
                        }
                    }
                }
            }
            .listStyle(GroupedListStyle())
            .navigationTitle(NSLocalizedString("File Info", comment: ""))
            .navigationBarItems(trailing: Button(NSLocalizedString("Done", comment: "")) {
                presentationMode.wrappedValue.dismiss()
            })
            .floatingToast(message: $toastMessage)
        }
    }
    
    private func copyPathToClipboard(_ path: String, message: String? = nil) {
        #if os(iOS)
        UIPasteboard.general.string = path
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #endif
        toastMessage = message ?? NSLocalizedString("Path Copied to Clipboard", comment: "")
    }
}
