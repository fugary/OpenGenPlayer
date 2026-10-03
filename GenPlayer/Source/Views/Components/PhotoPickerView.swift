import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

#if os(iOS)
struct PhotoPickerView: UIViewControllerRepresentable {
    let targetDirectory: URL
    let onComplete: (Int) -> Void

    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 0 // 0 allows unlimited selection
        configuration.filter = .any(of: [.videos, .images])
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerView

        init(_ parent: PhotoPickerView) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentationMode.wrappedValue.dismiss()

            guard !results.isEmpty else { return }

            Task.detached(priority: .userInitiated) {
                var importedCount = 0
                let fileManager = FileManager.default
                let destinationDir = self.parent.targetDirectory

                for result in results {
                    let provider = result.itemProvider
                    let didImport = await self.importItemProvider(provider, to: destinationDir, fileManager: fileManager)
                    if didImport {
                        importedCount += 1
                    }
                }

                let finalCount = importedCount
                await MainActor.run {
                    self.parent.onComplete(finalCount)
                }
            }
        }

        private func importItemProvider(_ provider: NSItemProvider, to destinationDir: URL, fileManager: FileManager) async -> Bool {
            let supportedTypes: [UTType] = [
                .quickTimeMovie,
                .mpeg4Movie,
                .movie,
                .video,
                .heic,
                .jpeg,
                .png,
                .image,
                .data
            ]

            for utType in supportedTypes {
                if provider.hasItemConformingToTypeIdentifier(utType.identifier) {
                    let imported = await withCheckedContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: utType.identifier) { tempURL, error in
                            guard let tempURL = tempURL, error == nil else {
                                continuation.resume(returning: false)
                                return
                            }

                            do {
                                let suggestedFilename = provider.suggestedName.flatMap { name -> String in
                                    let ext = tempURL.pathExtension
                                    if !ext.isEmpty && !name.hasSuffix("." + ext) {
                                        return "\(name).\(ext)"
                                    }
                                    return name
                                } ?? tempURL.lastPathComponent

                                let destinationURL = self.uniqueFileURL(for: suggestedFilename, in: destinationDir, fileManager: fileManager)
                                try fileManager.copyItem(at: tempURL, to: destinationURL)
                                continuation.resume(returning: true)
                            } catch {
                                print("Error copying imported asset: \(error)")
                                continuation.resume(returning: false)
                            }
                        }
                    }

                    if imported {
                        return true
                    }
                }
            }

            return false
        }

        private func uniqueFileURL(for filename: String, in directory: URL, fileManager: FileManager) -> URL {
            var targetURL = directory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: targetURL.path) else {
                return targetURL
            }

            let baseName = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            var counter = 1

            while fileManager.fileExists(atPath: targetURL.path) {
                let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
                targetURL = directory.appendingPathComponent(newName)
                counter += 1
            }

            return targetURL
        }
    }
}
#endif
