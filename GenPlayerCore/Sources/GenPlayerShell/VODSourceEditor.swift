#if os(iOS) || os(tvOS)
import SwiftUI
import CryptoKit
import GenPlayerCore

/// Embedded in each platform's server form; it never saves credentials or other servers.
public struct VODSourceEditor: View {
    @Binding var sources: [VODSourceConfig]
    @State private var removal: UUID?
    public init(sources: Binding<[VODSourceConfig]>) { _sources = sources }
    public static func valid(_ sources: [VODSourceConfig]) -> Bool {
        sources.contains(where: \.isEnabled) && sources.allSatisfy {
            let url = URLComponents(string: $0.address.trimmingCharacters(in: .whitespacesAndNewlines))
            return !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
                && !(url?.host ?? "").isEmpty && url?.user == nil && url?.password == nil
        }
    }
    public var body: some View {
        ForEach($sources) { $source in
            VStack(alignment: .leading, spacing: 12) {
                TextField(platformShellString("Name"), text: $source.name)
                TextField(platformShellString("API URL"), text: $source.address)
                    .disableAutocorrection(true)
                Toggle(platformShellString("Enabled"), isOn: $source.isEnabled)
                Button(role: .destructive) { removal = source.id } label: { Text(platformShellString("Delete")) }
                    .disabled(sources.count == 1)
            }.padding(.vertical, 8)
        }
        Button(platformShellString("Add Source")) { sources.append(VODSourceConfig(name: "", address: "")) }
            .alert(platformShellString("Remove VOD Source?"), isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                Button(platformShellString("Delete"), role: .destructive) { sources.removeAll { $0.id == removal }; removal = nil }
                Button(platformShellString("Cancel"), role: .cancel) { removal = nil }
            }
    }
}
public extension ServerConfig {
    var mobileVODSummaryEndpoints: [ServerConfig] {
        vodEndpoints.map { source in
            var endpoint = source
            let key = id.uuidString + ":" + source.id.uuidString + ":" + source.fullURL
            let b = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
            endpoint.id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            return endpoint
        }
    }
    var mobileMediaSummary: MediaServerSummary? {
        let service = MediaServerSummaryService.shared
        guard type == .vod else { return service.summary(for: id) }
        return mobileVODSummaryEndpoints.compactMap { service.summary(for: $0.id) }.max { $0.libraryCount < $1.libraryCount }
    }
    @MainActor func refreshMobileVODSummaries(onlyMissing: Bool = true) async {
        guard type == .vod else { return }
        let service = MediaServerSummaryService.shared
        let endpoints = mobileVODSummaryEndpoints
        for start in stride(from: 0, to: endpoints.count, by: 3) {
            guard !Task.isCancelled else { return }
            let batch = endpoints[start..<min(start + 3, endpoints.count)].filter {
                !service.loadingServers.contains($0.id) && (!onlyMissing || service.summary(for: $0.id) == nil)
            }
            await withTaskGroup(of: Void.self) { group in
                for endpoint in batch { group.addTask { await service.refreshSummary(for: endpoint) } }
            }
        }
    }
}
#endif

#if os(iOS) || os(tvOS)
public struct VODDetailMetadata: View {
    let item: VODItem
    let server: ServerConfig
    public init(item: VODItem, server: ServerConfig) { self.item = item; self.server = server }
    private var people: [String] {
        var seen = Set<String>()
        return [item.vodDirector, item.vodActor].compactMap { $0 }.joined(separator: ",")
            .components(separatedBy: CharacterSet(charactersIn: ",，、;/；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var portraitSize: CGFloat {
        #if os(tvOS)
        return 130
        #else
        return 90
        #endif
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !people.isEmpty {
                Text(platformShellString("Cast & Crew")).font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(people, id: \.self) { name in
                            VStack(spacing: 10) {
                                Image(systemName: "person.fill").font(.largeTitle)
                                    .frame(width: portraitSize, height: portraitSize)
                                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                                Text(name).font(.caption).lineLimit(2)
                                    .frame(width: portraitSize + 20, height: 56, alignment: .top)
                            }.foregroundColor(.secondary)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(platformShellString("Media Info")).font(.headline)
                row("Server Info", server.name)
                row("Language", item.vodLanguage?.value)
                row("Duration", item.vodDuration?.value)
                row("Updated", item.vodTime)
                #if os(iOS)
                if let id = item.vodDoubanID?.value, let number = Int(id), number > 0,
                   let url = URL(string: "https://movie.douban.com/subject/\(number)/") {
                    Link(platformShellString("Douban"), destination: url)
                }
                #endif
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        }
    }
    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty, value != "0" {
            VStack(alignment: .leading, spacing: 4) {
                Text(platformShellString(label)).font(.caption).foregroundColor(.secondary)
                Text(value).font(.body)
            }
        }
    }
}
#endif
