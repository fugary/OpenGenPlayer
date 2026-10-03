#if os(macOS)
import Foundation
import CryptoKit
import SwiftUI
import GenPlayerCore

extension ServerConfig {
    // Summary identity includes the address so edits and late responses cannot reuse old counts.
    var macVODSummaryEndpoints: [ServerConfig] {
        macVODEndpoints.map { endpoint in
            var summaryEndpoint = endpoint
            let key = id.uuidString + ":" + endpoint.id.uuidString + ":" + endpoint.fullURL
            let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
            summaryEndpoint.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            return summaryEndpoint
        }
    }

    var macVODSources: [VODSourceConfig] {
        vodSources ?? [VODSourceConfig(id: id, name: name, address: fullURL)]
    }

    func macVODRecordID(ownerID: UUID, itemID: String) -> String {
        ownerID == id ? itemID : "vod:" + id.uuidString + ":" + itemID
    }

    func macVODResolveRecord(_ record: String) -> (source: ServerConfig, itemID: String)? {
        let parts = record.split(separator: ":", maxSplits: 2).map(String.init)
        let qualified = parts.count == 3 && parts[0] == "vod"
        let sourceID = qualified ? UUID(uuidString: parts[1]) : id
        guard let source = macVODEndpoints.first(where: { $0.id == sourceID }) else { return nil }
        return (source, qualified ? parts[2] : record)
    }

    var macVODEndpoints: [ServerConfig] {
        macVODSources.filter(\.isEnabled).map { source in
            ServerConfig(id: source.id, name: source.name, address: source.address, type: .vod)
        }
    }
}

struct MacVODSourcesEditor: View {
    @Binding var sources: [VODSourceConfig]
    @State private var removal: UUID?

    static func valid(_ sources: [VODSourceConfig]) -> Bool {
        sources.contains(where: \.isEnabled) && sources.allSatisfy { source in
            let url = URLComponents(string: source.address.trimmingCharacters(in: .whitespacesAndNewlines))
            return !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
                && !(url?.host ?? "").isEmpty && url?.user == nil && url?.password == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(platformShellString("VOD Sources")).font(.headline)
            Text(platformShellString("VOD Default Source Hint")).font(.caption).foregroundColor(.secondary)
            ForEach($sources) { $source in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(platformShellString("Name"), text: $source.name)
                        Toggle(platformShellString("Enabled"), isOn: $source.isEnabled)
                        Button { move(source.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .help(platformShellString("Move Up")).disabled(sources.first?.id == source.id)
                        Button { move(source.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .help(platformShellString("Move Down")).disabled(sources.last?.id == source.id)
                        Button(role: .destructive) { removal = source.id } label: { Image(systemName: "trash") }
                            .help(platformShellString("Delete")).disabled(sources.count == 1)
                    }
                    TextField(platformShellString("API URL"), text: $source.address)
                }.textFieldStyle(.roundedBorder)
            }
            Button(platformShellString("Add Source")) {
                sources.append(VODSourceConfig(name: "", address: ""))
            }
        }
        .alert(platformShellString("Remove VOD Source?"), isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button(platformShellString("Delete"), role: .destructive) {
                sources.removeAll { $0.id == removal }; removal = nil
            }
            Button(platformShellString("Cancel"), role: .cancel) { removal = nil }
        }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }), sources.indices.contains(index + delta) else { return }
        sources.swapAt(index, index + delta)
    }
}
extension ServerConfig {
    @MainActor func macRefreshVODSummaries(onlyMissing: Bool) async {
        let service = MediaServerSummaryService.shared
        if macVODSources.count <= 1 {
            guard !service.loadingServers.contains(id),
                  !onlyMissing || service.summary(for: id) == nil else { return }
            await service.refreshSummary(for: self)
            return
        }
        let endpoints = macVODSummaryEndpoints
        for start in stride(from: 0, to: endpoints.count, by: 3) {
            guard !Task.isCancelled else { return }
            let batch = endpoints[start..<min(start + 3, endpoints.count)].filter {
                !service.loadingServers.contains($0.id)
                    && (!onlyMissing || service.summary(for: $0.id) == nil)
            }
            await withTaskGroup(of: Void.self) { group in
                for endpoint in batch {
                    group.addTask { await service.refreshSummary(for: endpoint) }
                }
            }
        }
    }

}
#endif
