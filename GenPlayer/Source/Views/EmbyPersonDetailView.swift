import SwiftUI

struct EmbyPersonDetailView: View {
    let server: ServerConfig
    let person: EmbyPerson
    var onExit: (() -> Void)? = nil
    
    @State private var items: [EmbyItem] = []
    @State private var personDetails: EmbyItem?
    @State private var isLoadingItems = false
    @State private var sortBy = "DateCreated"
    @State private var sortOrder = "Descending"
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.presentationMode) private var presentationMode

    private let sortOptions = [
        ("SortName", NSLocalizedString("Name", comment: "")),
        ("DateCreated", NSLocalizedString("Date Added", comment: "")),
        ("PremiereDate", NSLocalizedString("Release Date", comment: "")),
        ("ProductionYear", NSLocalizedString("Release Year", comment: "")),
        ("CommunityRating", NSLocalizedString("Rating", comment: "")),
        ("Resolution", NSLocalizedString("Resolution", comment: "")),
        ("Runtime", NSLocalizedString("Runtime", comment: ""))
    ]

    @Environment(\.horizontalSizeClass) private var personHorizontalSizeClass

    private var usesWideLayout: Bool {
        personHorizontalSizeClass == .regular
    }

    private var titleFont: Font {
        usesWideLayout ? .title : .title2
    }

    private var subtitleFont: Font {
        usesWideLayout ? .title3 : .body
    }

    private var headerImageWidth: CGFloat {
        usesWideLayout ? 156 : 108
    }

    private var headerImageHeight: CGFloat {
        headerImageWidth * 1.5
    }

    private var personCardWidth: CGFloat {
        usesWideLayout ? 148 : 112
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: personCardWidth,
                    maximum: usesWideLayout ? 176 : 132
                ),
                spacing: usesWideLayout ? 18 : 14,
                alignment: .top
            )
        ]
    }

    private var biography: String? {
        cleanedPersonText(personDetails?.overview)
    }

    private var roleText: String? {
        cleanedPersonText(person.role)
    }

    private var typeText: String? {
        localizedPersonTypeText(cleanedPersonText(person.type))
    }

    private var detailRows: [(title: String, value: String)] {
        var rows: [(String, String)] = []

        if let born = personDateText(personDetails?.premiereDate) {
            rows.append((NSLocalizedString("Born", comment: ""), born))
        }
        if let died = personDateText(personDetails?.endDate) {
            rows.append((NSLocalizedString("Died", comment: ""), died))
        }
        if let placeOfBirth = locationText(from: personDetails?.productionLocations) {
            rows.append((NSLocalizedString("Place of Birth", comment: ""), placeOfBirth))
        }
        if let providerSummary = providerSummaryText(personDetails?.providerIds) {
            rows.append((NSLocalizedString("External IDs", comment: ""), providerSummary))
        }
        if let website = websiteText(personDetails?.homePageUrl) {
            rows.append((NSLocalizedString("Website", comment: ""), website))
        }

        return rows
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
    
                    if let biography {
                        personSection(title: NSLocalizedString("Biography", comment: "")) {
                            Text(biography)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
    
                    VStack(alignment: .leading, spacing: 14) {
                        Text(NSLocalizedString("Known For", comment: ""))
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if isLoadingItems {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else if items.isEmpty {
                            Text(NSLocalizedString("No items found", comment: ""))
                                .foregroundColor(.secondary)
                        } else {
                            MediaLibraryCardGrid(columns: columns, spacing: usesWideLayout ? 18 : 14, legacyCardWidth: personCardWidth) { columnWidth in
                                ForEach(items) { item in
                                    NavigationLink(destination: NavigationLazyView { AnyView(embyNavigationDestination(server: server, item: item, onExit: onExit)) }) {
                                        EmbyPosterCard(item: item, server: server, showProgress: false, cardWidth: columnWidth)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, usesWideLayout ? 24 : 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitle(person.name, displayMode: .inline)
        .libraryChildNavigationBarCompat()
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    AppToolbarIcon(systemName: "chevron.left")
                }
                Button(action: {
                    self.popToServerRoot()
                }) {
                    AppToolbarIcon(systemName: "house")
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                
                    Menu {
                        Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                            ForEach(sortOptions, id: \.0) { option in
                                Button(action: {
                                    updateSortField(option.0)
                                }) {
                                    sortMenuRow(title: option.1, isSelected: sortBy == option.0)
                                }
                            }
                        }

                        Section(header: Text(NSLocalizedString("Sort Order", comment: ""))) {
                            Button(action: {
                                updateSortOrder("Ascending")
                            }) {
                                sortMenuRow(
                                    title: NSLocalizedString("Ascending", comment: ""),
                                    isSelected: sortOrder == "Ascending"
                                )
                            }
                            Button(action: {
                                updateSortOrder("Descending")
                            }) {
                                sortMenuRow(
                                    title: NSLocalizedString("Descending", comment: ""),
                                    isSelected: sortOrder == "Descending"
                                )
                            }
                        }
                    } label: {
                        AppToolbarIcon(systemName: "line.3.horizontal.decrease.circle")
                    }
                
            }
        }
        .customBackButton()
        .onAppear {
            loadSavedSortPreference()
            if items.isEmpty {
                Task { await loadKnownForItems() }
            }
            if personDetails == nil {
                Task { await loadPersonDetailsIfNeeded() }
            }
        }
    }
    
    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let imageURL = personImageURL {
                    RemoteImage(url: imageURL)
                        .aspectRatio(2/3, contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.tertiarySystemFill))

                        Image(systemName: "person.fill")
                            .font(.system(size: usesWideLayout ? 44 : 36))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                    }
                }
            }
            .frame(width: headerImageWidth, height: headerImageHeight)
            .cornerRadius(16)
            .clipped()

            VStack(alignment: .leading, spacing: 10) {
                Text(person.name)
                    .font(titleFont)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)

                if let roleText {
                    Text(roleText)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let typeText {
                    Text(typeText)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(999)
                }

                if !detailRows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(detailRows.enumerated()), id: \.offset) { entry in
                            let row = entry.element
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(row.value)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var personImageURL: URL? {
        person.primaryImageURL(server: server, maxWidth: 400)
            ?? personDetails?.primaryImageURL(server: server, maxWidth: 400)
    }

    @ViewBuilder
    private func sortMenuRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func updateSortField(_ newSortBy: String) {
        guard sortBy != newSortBy else { return }
        sortBy = newSortBy
        if newSortBy == "SortName" && sortOrder != "Ascending" {
            sortOrder = "Ascending"
        }
        if newSortBy != "SortName" && sortOrder != "Descending" {
            sortOrder = "Descending"
        }
        persistSortPreferenceAndReload()
    }

    private func updateSortOrder(_ newSortOrder: String) {
        guard sortOrder != newSortOrder else { return }
        sortOrder = newSortOrder
        persistSortPreferenceAndReload()
    }

    private func persistSortPreferenceAndReload() {
        settings.saveLibrarySortPreference(
            provider: "emby-person",
            serverId: server.id.uuidString,
            libraryId: person.id,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
        Task { await loadKnownForItems() }
    }

    private func loadSavedSortPreference() {
        let saved = settings.librarySortPreference(
            provider: "emby-person",
            serverId: server.id.uuidString,
            libraryId: person.id,
            defaultSortBy: sortBy,
            defaultSortOrder: sortOrder
        )
        sortBy = saved.sortBy
        sortOrder = saved.sortOrder
    }

    @ViewBuilder
    private func personSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            content()
        }
        .padding(.top, 4)
    }

    private func loadPersonDetailsIfNeeded() async {
        guard let token = server.accessToken, let userId = server.userId else { return }

        let details = await loadPersonDetails(userId: userId, token: token)
        await MainActor.run {
            personDetails = details
        }
    }

    private func loadKnownForItems() async {
        guard let token = server.accessToken, let userId = server.userId else { return }

        await MainActor.run { isLoadingItems = true }
        let knownForItems = await loadPersonItems(userId: userId, token: token)

        await MainActor.run {
            items = knownForItems
            isLoadingItems = false
        }
    }

    private func loadPersonDetails(userId: String, token: String) async -> EmbyItem? {
        do {
            return try await EmbyService.shared.getItemDetails(server: server, userId: userId, itemId: person.id, token: token)
        } catch {
            print("Failed to load Emby person details: \(error)")
            return nil
        }
    }

    private func loadPersonItems(userId: String, token: String) async -> [EmbyItem] {
        do {
            let loadedItems = try await EmbyService.shared.getPersonItems(
                server: server,
                personId: person.id,
                userId: userId,
                token: token,
                sortBy: serverSortBy,
                sortOrder: sortOrder,
                limit: usesLocalSort ? 100 : 50
            )
                .filter { $0.type != "Person" }
            return sortedItems(loadedItems)
        } catch {
            print("Failed to load Emby person items: \(error)")
            return []
        }
    }

    private var usesLocalSort: Bool {
        sortBy == "Resolution" || sortBy == "PremiereDate" || sortBy == "ProductionYear"
    }

    private var serverSortBy: String {
        sortBy == "Resolution" ? "SortName" : sortBy
    }

    private func sortedItems(_ loadedItems: [EmbyItem]) -> [EmbyItem] {
        switch sortBy {
        case "Resolution":
            return sortedItems(loadedItems) { item in
                let pixels = item.bestVideoPixelCount
                return pixels > 0 ? pixels : nil
            }
        case "PremiereDate":
            return sortedItems(loadedItems) { $0.premiereDateSortValue }
        case "ProductionYear":
            return sortedItems(loadedItems) { $0.productionYearSortValue }
        default:
            return loadedItems
        }
    }

    private func sortedItems(
        _ loadedItems: [EmbyItem],
        value: (EmbyItem) -> Int?
    ) -> [EmbyItem] {
        let isAscending = sortOrder == "Ascending"
        return loadedItems.sorted { lhs, rhs in
            let lhsValue = value(lhs)
            let rhsValue = value(rhs)
            if let lhsValue, let rhsValue, lhsValue != rhsValue {
                return isAscending ? lhsValue < rhsValue : lhsValue > rhsValue
            }
            if lhsValue != nil && rhsValue == nil {
                return true
            }
            if lhsValue == nil && rhsValue != nil {
                return false
            }
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private func cleanedPersonText(_ value: String?) -> String? {
        guard let value else { return nil }

        let normalizedBreaks = value
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
        let withoutTags = normalizedBreaks.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let trimmed = withoutTags
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? nil : trimmed
    }

    private func personDateText(_ rawValue: String?) -> String? {
        guard let rawValue = cleanedPersonText(rawValue) else { return nil }

        let displayFormatter = DateFormatter()
        displayFormatter.locale = .current
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .none

        let formatters: [DateFormatter] = [
            formatter(for: "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSXXXXX"),
            formatter(for: "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"),
            formatter(for: "yyyy-MM-dd'T'HH:mm:ssXXXXX"),
            formatter(for: "yyyy-MM-dd")
        ]

        for formatter in formatters {
            if let date = formatter.date(from: rawValue) {
                return displayFormatter.string(from: date)
            }
        }

        if rawValue.count >= 10 {
            let prefix = String(rawValue.prefix(10))
            if let date = formatter(for: "yyyy-MM-dd").date(from: prefix) {
                return displayFormatter.string(from: date)
            }
            return prefix
        }

        return rawValue
    }

    private func formatter(for dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = dateFormat
        return formatter
    }

    private func locationText(from values: [String]?) -> String? {
        let locations = (values ?? [])
            .compactMap { cleanedPersonText($0) }
        let uniqueLocations = Array(NSOrderedSet(array: locations)) as? [String] ?? locations
        guard !uniqueLocations.isEmpty else { return nil }
        return uniqueLocations.joined(separator: " · ")
    }

    private func providerSummaryText(_ providerIds: [String: String]?) -> String? {
        let names = (providerIds ?? [:]).compactMap { key, value -> String? in
            guard let cleanedValue = cleanedPersonText(value) else { return nil }
            return "\(providerDisplayName(for: key)): \(cleanedValue)"
        }
        .sorted()

        guard !names.isEmpty else { return nil }
        return names.joined(separator: " · ")
    }

    private func websiteText(_ rawValue: String?) -> String? {
        guard let rawValue = cleanedPersonText(rawValue),
              let url = URL(string: rawValue),
              let host = url.host else {
            return cleanedPersonText(rawValue)
        }
        return host
    }

    private func localizedPersonTypeText(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        switch rawValue.lowercased() {
        case "actor":
            return NSLocalizedString("Actor", comment: "")
        case "director":
            return NSLocalizedString("Director", comment: "")
        default:
            return rawValue
        }
    }

    private func providerDisplayName(for key: String) -> String {
        switch key.lowercased() {
        case "imdb":
            return "IMDb"
        case "tmdb":
            return "TMDb"
        case "tvdb":
            return "TVDB"
        case "musicbrainzartist":
            return "MusicBrainz"
        default:
            return key.uppercased()
        }
    }
}
