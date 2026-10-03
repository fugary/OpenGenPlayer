#if os(macOS)
import Foundation
import GenPlayerCore

/// Authorization identity is independent of the URL returned by a bookmark.
struct MacLocalBrowserEntry: Identifiable {
    enum ID: Hashable {
        case authorizedFolder(UUID)
        case file(URL)
    }

    let file: VideoFile
    let authorizedFolderID: UUID?

    init(file: VideoFile, authorizedFolderID: UUID? = nil) {
        self.file = file
        self.authorizedFolderID = authorizedFolderID
    }

    var id: ID {
        if let authorizedFolderID {
            return .authorizedFolder(authorizedFolderID)
        }
        return .file(file.url)
    }

    func authorizedFolder(in folders: [MacAuthorizedFolder]) -> MacAuthorizedFolder? {
        guard let authorizedFolderID else { return nil }
        return folders.first { $0.id == authorizedFolderID }
    }
}
#endif
