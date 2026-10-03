#if os(macOS)
import Foundation
import SwiftUI
import GenPlayerCore

/// Address reachability only: no decoder or sustained-bandwidth claims.
actor MacVODAddressProbe {
    static let shared = MacVODAddressProbe()
    struct Status { let text: String; let reachable: Bool }
    private var cache: [URL: (Date, Status)] = [:]
    private var active = 0
    private let protocols: [AnyClass]?
    init(protocols: [AnyClass]? = nil) { self.protocols = protocols }

    func check(_ url: URL, force: Bool = false) async throws -> Status {
        if !force, let cached = cache[url], Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        while active >= 3 { try await Task.sleep(nanoseconds: 100_000_000) }
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        let start = Date()
        let status: Status
        do {
            try await inspect(url, depth: 0)
            status = Status(text: platformShellString("VOD Address Reachable") + " · \(Int(Date().timeIntervalSince(start) * 1000)) ms", reachable: true)
        } catch {
            try Task.checkCancellation()
            status = Status(text: error.localizedDescription, reachable: false)
        }
        try Task.checkCancellation()
        if cache.count > 200 { cache.removeAll() }
        cache[url] = (Date(), status)
        return status
    }

    private func inspect(_ url: URL, depth: Int) async throws {
        guard depth < 4, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let config = URLSessionConfiguration.ephemeral
        if let protocols { config.protocolClasses = protocols }
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(VODService.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "VODProbe", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 65536 { break }
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("#EXTM3U") {
            // Ignore an incomplete last line when the read cap was reached.
            var lines = text.components(separatedBy: .newlines)
            if data.count == 65536 { lines.removeLast() }
            guard let path = lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let next = URL(string: path, relativeTo: response.url ?? url)?.absoluteURL else { throw URLError(.cannotParseResponse) }
            try await inspect(next, depth: depth + 1)
        } else if url.pathExtension.lowercased() == "m3u8" || text.lowercased().hasPrefix("<!doctype") || text.lowercased().hasPrefix("<html") || response.mimeType == "text/html" {
            throw NSError(domain: "VODProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: platformShellString("VOD Invalid Media Response")])
        }
    }
}

enum MacVODEpisodeMatch {
    static func key(_ name: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.range(of: "^(第[0-9]+集|ep?[ .]*[0-9]+|episode[ .]*[0-9]+|[0-9]+)$", options: .regularExpression) != nil {
            let digits = value.filter(\.isNumber)
            if let number = Int(digits) { return "episode:\(number)" }
        }
        return value
    }
    static func match(_ episode: VODEpisode, in episodes: [VODEpisode]) -> VODEpisode? {
        let matches = episodes.filter { key($0.name) == key(episode.name) }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct MacVODSourceSwitchView: View {
    let file: VideoFile
    let onClose: () -> Void
    let onSelect: (VideoFile, [VideoFile], Bool) -> Void
    @State private var choices: [Choice] = []
    @State private var errors: [String] = []
    @State private var loading = true
    struct Choice: Identifiable {
        let server: ServerConfig
        let ownerID: UUID
        let item: VODItem
        let source: VODPlaySource
        let original: VODEpisode
        var id: String { server.id.uuidString + ":" + item.id + ":" + String(source.index) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(platformShellString("Sources")).font(.headline)
                    .foregroundColor(.white)
                    .help(platformShellString("VOD Probe Disclaimer"))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7)).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding()
            .background(Color.black.opacity(0.4))
            Text(file.name).font(.subheadline).lineLimit(2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            Divider()
            ScrollView(showsIndicators: false) {
                choicesContent.padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Rectangle()
                    .fill(Color.black.opacity(0.55))
            }
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: -2, y: 0)
        .ignoresSafeArea()
        .task(id: file.id) { await load() }
    }

    private var choicesContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(choices) { choice in
                MacVODSourceChoiceRow(choice: choice, currentURL: file.url) { selected, playlist, matched in
                    onSelect(selected, playlist, matched)
                }
            }
            ForEach(Array(errors.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundColor(.secondary) }
            if loading { ProgressView() }
            if !loading && choices.isEmpty { Text(platformShellString("No episodes found")) }
        }
    }

    @MainActor private func load() async {
        choices = []; errors = []; loading = true
        defer { if !Task.isCancelled { loading = false } }
        guard let ownerID = file.jellyfinServerId.flatMap(UUID.init(uuidString:)),
              let owner = AppNetworkService.shared.servers.first(where: { $0.id == ownerID }),
              let record = file.seriesId, let resolved = owner.macVODResolveRecord(record) else { return }
        do {
            guard let current = try await VODService.shared.fetchDetail(server: resolved.source, vodId: resolved.itemID) else { return }
            let exact = current.playSources.flatMap(\.episodes).first(where: { $0.url == file.url })
            // Signed addresses can change. Recover by the original episode name, never array position.
            let prefix = current.vodName + " - "
            let name = file.name.hasPrefix(prefix) ? String(file.name.dropFirst(prefix.count)) : ""
            let sameLine = current.playSources.first { String($0.index) == file.seasonId }
            let named = sameLine?.episodes.filter { !$0.name.isEmpty && $0.name == name } ?? []
            guard let original = exact ?? (named.count == 1 ? named.first : nil) else { return }
            try Task.checkCancellation()
            choices = current.playSources.map { Choice(server: resolved.source, ownerID: ownerID, item: current, source: $0, original: original) }
            let otherSources = owner.macVODEndpoints.filter { $0.id != resolved.source.id }
            for start in stride(from: 0, to: otherSources.count, by: 3) {
                try Task.checkCancellation()
                await withTaskGroup(of: ([Choice], String?).self) { group in
                    for endpoint in otherSources[start..<min(start + 3, otherSources.count)] {
                        group.addTask {
                            do {
                                let result = try await VODService.shared.search(server: endpoint, keyword: current.vodName)
                                guard let year = current.vodYear, Int(year).map({ $0 > 0 }) == true,
                                      let match = result.items.first(where: { $0.vodName.trimmingCharacters(in: .whitespacesAndNewlines) == current.vodName.trimmingCharacters(in: .whitespacesAndNewlines) && $0.vodYear == year && MacVODContentKind.classify($0.typeName ?? "") == MacVODContentKind.classify(current.typeName ?? "") }),
                                      let detail = try await VODService.shared.fetchDetail(server: endpoint, vodId: match.id) else { return ([], nil) }
                                return (detail.playSources.map { Choice(server: endpoint, ownerID: ownerID, item: detail, source: $0, original: original) }, nil)
                            } catch { return ([], endpoint.name + ": " + error.localizedDescription) }
                        }
                    }
                    for await (found, error) in group {
                        guard !Task.isCancelled else { group.cancelAll(); return }
                        choices += found
                        if let error { errors.append(error) }
                    }
                }
            }
        } catch { if !Task.isCancelled { errors.append(error.localizedDescription) } }
    }
}

private struct MacVODSourceChoiceRow: View {
    let choice: MacVODSourceSwitchView.Choice
    let currentURL: URL
    let onSelect: (VideoFile, [VideoFile], Bool) -> Void
    @State private var status: MacVODAddressProbe.Status?
    @State private var refresh = 0
    private var matched: VODEpisode? { MacVODEpisodeMatch.match(choice.original, in: choice.source.episodes) }
    private var selected: VODEpisode? { matched }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { play() } label: {
                HStack(spacing: 6) {
                    Image(systemName: selected?.url == currentURL ? "checkmark.circle.fill" : "play.circle")
                    Text(choice.server.name + " · " + choice.source.name).font(.caption.weight(.semibold))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(selected == nil)
            if selected == nil {
                Text(platformShellString("VOD No Matching Episode")).font(.caption).foregroundColor(.secondary)
            }
            HStack {
                if let status {
                    Label(status.text, systemImage: status.reachable ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundColor(status.reachable ? .green : .orange)
                } else if selected != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button { refresh += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help(platformShellString("Retry")).disabled(selected == nil)
            }.font(.caption2)
            Divider()
        }
        .task(id: (selected?.id ?? "") + ":\(refresh)") {
            status = nil
            guard let episode = selected else { return }
            do {
                let result = try await MacVODAddressProbe.shared.check(episode.url, force: refresh > 0)
                try Task.checkCancellation()
                status = result
            } catch { }
        }
    }
    private func play() {
        guard let episode = selected else { return }
        func make(_ ep: VODEpisode) -> VideoFile {
            var result = VODService.shared.makeVideoFile(for: ep, item: choice.item, server: choice.server, source: choice.source)
            result.jellyfinServerId = choice.ownerID.uuidString
            result.seriesId = choice.server.macVODRecordID(ownerID: choice.ownerID, itemID: choice.item.id)
            return result
        }
        onSelect(make(episode), choice.source.episodes.map(make), matched?.id == episode.id)
    }
}
#endif
