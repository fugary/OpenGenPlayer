import Foundation
import GenPlayerCore

public class MacNavigationManager: ObservableObject {
    public static let shared = MacNavigationManager()
    @Published public var targetFileToResolve: VideoFile? = nil
    @Published public var targetLocalFolderURL: URL? = nil
    @Published public var targetSeasonId: String? = nil
    @Published public var targetEpisodeId: String? = nil
    @Published var returnTabSelection: PlatformShellDestination? = nil
    @Published public var targetSettingsTab: String? = nil
}

enum PlatformShellDestination: Hashable, Identifiable {
    case localFiles
    case servers
    case history
    case favorites
    case downloads
    case settings
    case server(UUID)

    static let primaryItems: [PlatformShellDestination] = {
        #if os(macOS)
        return [
            .localFiles,
            .servers,
            .history,
            .favorites,
            .downloads,
            .settings,
        ]
        #else
        return [
            .localFiles,
            .servers,
            .history,
            .favorites,
            .settings,
        ]
        #endif
    }()

    var id: String {
        switch self {
        case .localFiles:
            return "localFiles"
        case .servers:
            return "servers"
        case .history:
            return "history"
        case .favorites:
            return "favorites"
        case .downloads:
            return "downloads"
        case .settings:
            return "settings"
        case .server(let identifier):
            return "server-\(identifier.uuidString)"
        }
    }

    var titleKey: String {
        switch self {
        case .localFiles:
            return "Local"
        case .servers:
            return "Network"
        case .history:
            return "Play History"
        case .favorites:
            return "Favorites"
        case .downloads:
            return "Downloads"
        case .settings:
            return "Settings"
        case .server:
            return "Server"
        }
    }

    var systemImageName: String {
        switch self {
        case .localFiles:
            return "folder"
        case .servers:
            return "network"
        case .history:
            return "clock.arrow.circlepath"
        case .favorites:
            return "star"
        case .downloads:
            return "arrow.down.circle"
        case .settings:
            return "gearshape"
        case .server:
            return "server.rack"
        }
    }

    var localizedTitle: String {
        platformShellString(titleKey)
    }
}

extension PlatformShellDestination {
    static func normalized(_ selection: PlatformShellDestination?, servers: [ServerConfig]) -> PlatformShellDestination {
        guard let selection else {
            return .servers
        }

        switch selection {
        case .server(let identifier):
            return servers.contains(where: { $0.id == identifier }) ? selection : .servers
        default:
            return selection
        }
    }
}
