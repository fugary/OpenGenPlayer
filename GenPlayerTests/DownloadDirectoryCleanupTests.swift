import Foundation
import Testing
@testable import GenPlayer

@MainActor
struct DownloadDirectoryCleanupTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: url)
    }

    private func clean(_ file: URL, root: URL) {
        DownloadCenterService.removeEmptyDownloadDirectories(afterRemoving: file, rootDirectory: root)
    }

    @Test func deletingLastEpisodeRemovesEmptyAncestorsButKeepsRoot() throws {
        try withDirectory { base in
            let root = base.appendingPathComponent("Downloads")
            let file = root.appendingPathComponent("Emby/Server/TV Shows/Series/Season 01/episode.mkv")
            try makeFile(file)
            try FileManager.default.removeItem(at: file)
            clean(file, root: root)
            #expect(FileManager.default.fileExists(atPath: root.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test(arguments: ["episode2.mkv", ".hidden", ".DS_Store"])
    func preservesRemainingFiles(name: String) throws {
        try withDirectory { base in
            let root = base.appendingPathComponent("Downloads")
            let file = root.appendingPathComponent("Server/Season/episode.mkv")
            let other = file.deletingLastPathComponent().appendingPathComponent(name)
            try makeFile(file)
            try makeFile(other)
            clean(file, root: root) // A failed deletion must not prune a nonempty folder.
            #expect(FileManager.default.fileExists(atPath: file.path))
            try FileManager.default.removeItem(at: file)
            clean(file, root: root)
            #expect(try Data(contentsOf: other) == Data("keep".utf8))
        }
    }

    @Test func batchDeletionOnlyPrunesAfterLastFile() throws {
        try withDirectory { base in
            let root = base.appendingPathComponent("Downloads")
            let files = (1...3).map { root.appendingPathComponent("Server/Season/episode\($0).mkv") }
            for file in files { try makeFile(file) }
            for (index, file) in files.enumerated() {
                try FileManager.default.removeItem(at: file)
                clean(file, root: root)
                for remaining in files.dropFirst(index + 1) {
                    #expect(FileManager.default.fileExists(atPath: remaining.path))
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func keepsOtherSeasonAndUnrelatedEmptyFolder() throws {
        try withDirectory { base in
            let root = base.appendingPathComponent("Downloads")
            let file = root.appendingPathComponent("Server/Series/Season 01/episode.mkv")
            let other = root.appendingPathComponent("Server/Series/Season 02/episode.mkv")
            let unrelated = root.appendingPathComponent("Unrelated")
            try makeFile(file)
            try makeFile(other)
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: file)
            clean(file, root: root)
            #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
            #expect(FileManager.default.fileExists(atPath: other.path))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
        }
    }

    @Test(arguments: ["Downloads-other/Server/file.mkv", "Downloads/../Outside/Server/file.mkv", "Downloads/file.mkv"])
    func respectsRootBoundary(path: String) throws {
        try withDirectory { base in
            let root = base.appendingPathComponent("Downloads")
            let file = base.appendingPathComponent(path).standardizedFileURL
            try makeFile(file)
            try FileManager.default.removeItem(at: file)
            clean(file, root: root)
            #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        }
    }

    @Test(arguments: ["Outside", "Downloads/Real"])
    func refusesSymbolicLinkAncestors(target: String) throws {
        try withDirectory { base in
            let root = base.appendingPathComponent("Downloads")
            let destination = base.appendingPathComponent(target)
            let file = destination.appendingPathComponent("Season/file.mkv")
            try makeFile(file)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("Link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            try FileManager.default.removeItem(at: file)
            clean(link.appendingPathComponent("Season/file.mkv"), root: root)
            #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
            #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        }
    }

    @Test func missingFileStillAllowsEmptyParentCleanup() throws {
        try withDirectory { base in
            let root = base.appendingPathComponent("Downloads")
            let file = root.appendingPathComponent("Server/Season/missing.mkv")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            clean(file, root: root)
            clean(file, root: root) // Repeated cleanup is harmless.
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
}
