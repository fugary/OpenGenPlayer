#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GenPlayerCore

public struct MacServerBackupAlertItem: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    
    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

@MainActor
public final class MacServerBackupManager: ObservableObject {
    public static let shared = MacServerBackupManager()

    @Published public var alertItem: MacServerBackupAlertItem? = nil

    private init() {}

    public func exportServers() {
        guard !AppNetworkService.shared.savedServers.isEmpty else {
            showAlert(
                title: platformShellString("Server Backup"),
                message: platformShellString("There are no saved servers to export.")
            )
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = makeServerBackupFileName() + ".json"
        panel.prompt = platformShellString("Export")
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let fileURL = panel.url {
            do {
                let data = try AppNetworkService.shared.exportServerBackupData()
                try data.write(to: fileURL)
            } catch {
                showAlert(
                    title: platformShellString("Server Backup"),
                    message: error.localizedDescription
                )
            }
        }
    }

    public func importServers() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.prompt = platformShellString("Import")

        if panel.runModal() == .OK, let fileURL = panel.url {
            let hasScopedAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let importResult = try AppNetworkService.shared.importServers(from: data)
                showAlert(
                    title: platformShellString("Server Backup"),
                    message: importSummaryMessage(for: importResult)
                )
            } catch {
                showAlert(
                    title: platformShellString("Server Backup"),
                    message: error.localizedDescription
                )
            }
        }
    }

    public func clearAllServers() {
        AppNetworkService.shared.clearAllServers()
    }

    public func showAlert(title: String, message: String) {
        self.alertItem = MacServerBackupAlertItem(title: title, message: message)
    }

    private func makeServerBackupFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "GenPlayer-Servers-\(formatter.string(from: Date()))"
    }

    private func importSummaryMessage(for result: ServerImportResult) -> String {
        if result.importedCount > 0 && result.skippedCount > 0 {
            return String(
                format: platformShellString("Imported %1$d servers. Skipped %2$d duplicate servers."),
                result.importedCount,
                result.skippedCount
            )
        }

        if result.importedCount > 0 {
            return String(
                format: platformShellString("Imported %d servers."),
                result.importedCount
            )
        }

        if result.skippedCount > 0 {
            return String(
                format: platformShellString("No new servers were imported. %d duplicates were skipped."),
                result.skippedCount
            )
        }

        return platformShellString("No new servers were imported.")
    }
}
#endif
