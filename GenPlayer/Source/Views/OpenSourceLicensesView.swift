import SwiftUI
import SafariServices

struct OpenSourceLibrary: Identifiable {
    let id = UUID()
    let name: String
    let licenseType: String
    let urlString: String
    let description: String
    
    var url: URL? {
        URL(string: urlString)
    }
}

let openSourceLibraries: [OpenSourceLibrary] = [
    OpenSourceLibrary(
        name: "GenPlayer",
        licenseType: "MIT",
        urlString: "https://github.com/fugary/OpenGenPlayer",
        description: "GenPlayer.SourceDescription"
    ),
    OpenSourceLibrary(
        name: "MPVKit / libmpv / FFmpeg",
        licenseType: "LGPL-3.0",
        urlString: "https://github.com/mpvkit/MPVKit/blob/1.0.0/LICENSE",
        description: "MPV.LicenseDescription"
    ),
    OpenSourceLibrary(
        name: "VLCKitSPM / MobileVLCKit",
        licenseType: "LGPL-2.1",
        urlString: "https://github.com/fugary/vlckit-spm/blob/main/LICENSE",
        description: "Swift Package wrapper for the MobileVLCKit / VLC playback stack used for audio and video playback."
    ),
    OpenSourceLibrary(
        name: "AMSMB2 (+ libsmb2)",
        licenseType: "LGPL-2.1",
        urlString: "https://github.com/amosavian/AMSMB2/blob/master/LICENSE",
        description: "SMB2/3 client framework used for SMB server access. The upstream project notes App Store distribution should use dynamic linking."
    ),
    OpenSourceLibrary(
        name: "FilesProvider",
        licenseType: "MIT",
        urlString: "https://github.com/amosavian/FileProvider/blob/master/LICENSE",
        description: "Remote file provider library used by the FTP browsing and transfer flow."
    ),
    OpenSourceLibrary(
        name: "libssh2",
        licenseType: "BSD 3-Clause",
        urlString: "https://github.com/libssh2/libssh2/blob/master/COPYING",
        description: "SSH2/SFTP client library bound directly by the app for SFTP directory browsing and downloads."
    ),
    OpenSourceLibrary(
        name: "NFSKit",
        licenseType: "MIT",
        urlString: "https://github.com/alexiscn/NFSKit/blob/main/LICENSE",
        description: "Swift package used for NFS server browsing and file download support."
    ),
    OpenSourceLibrary(
        name: "fishhook",
        licenseType: "BSD 3-Clause",
        urlString: "https://github.com/facebook/fishhook/blob/main/LICENSE",
        description: "A library that enables dynamically rebinding symbols in Mach-O binaries running on iOS."
    ),
    OpenSourceLibrary(
        name: "Source Han Sans SC",
        licenseType: "OFL-1.1",
        urlString: "https://github.com/adobe-fonts/source-han-sans/blob/master/LICENSE.txt",
        description: "Bundled Chinese font used as the fallback subtitle/UI font replacement for specific system font cases."
    )
]

struct OpenSourceLicensesView: View {
    @State private var selectedLibraryURL: URL?
    
    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("Open Source Licenses", comment: ""))) {
                ForEach(openSourceLibraries) { library in
                    Button(action: {
                        selectedLibraryURL = library.url
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(library.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(library.licenseType)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(4)
                                    .foregroundColor(.primary)
                            }
                            
                            Text(NSLocalizedString(library.description, comment: ""))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            
            Section(footer: Text(NSLocalizedString("For complete copyright and license details, please refer to each upstream project.", comment: ""))) {
                EmptyView()
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(NSLocalizedString("Open Source Licenses", comment: ""))
        .sheet(item: Binding<URLWrapper?>(
            get: { selectedLibraryURL != nil ? URLWrapper(url: selectedLibraryURL!) : nil },
            set: { selectedLibraryURL = $0?.url }
        )) { wrapper in
            SafariView(url: wrapper.url)
                .edgesIgnoringSafeArea(.all)
        }
    }
}

// Wrapper to conform to Identifiable for the .sheet modifier
struct URLWrapper: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: UIViewControllerRepresentableContext<SafariView>) -> SFSafariViewController {
        let safariVC = SFSafariViewController(url: url)
        // Configure standard appearance if needed
        return safariVC
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: UIViewControllerRepresentableContext<SafariView>) {
        // No updates needed
    }
}
