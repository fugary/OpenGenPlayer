import Foundation

enum PlexLibraryFilterField: String {
    case genre, year
}

struct PlexLibraryFilterChoice: Equatable {
    let title: String
    let value: String
}

enum PlexLibraryFilters {
    static func choices(from rows: [[String: Any]], field: PlexLibraryFilterField) -> [PlexLibraryFilterChoice] {
        var titles = Set<String>()
        return rows.compactMap { row -> PlexLibraryFilterChoice? in
            guard let title = row["title"] as? String, !title.isEmpty else { return nil }
            // Use the server's value, not its localized/display title. Extract
            // only the requested field; never follow an arbitrary returned URL.
            let fastKey = row["fastKey"] as? String
            let key = (row["key"] as? String) ?? (row["key"] as? NSNumber)?.stringValue
            let queryValue = [fastKey, key].compactMap { $0 }.compactMap {
                URLComponents(string: $0)?.queryItems?.first(where: { $0.name == field.rawValue })?.value
            }.first
            let pathValue = key.flatMap { key -> String? in
                let components = URLComponents(string: key)?.path.split(separator: "/") ?? []
                guard components.count >= 2, components[components.count - 2] == Substring(field.rawValue) else { return nil }
                return String(components[components.count - 1])
            }
            let rawValue = queryValue ?? pathValue ?? key
            guard let value = rawValue, !value.isEmpty,
                  !value.contains("/"), !value.contains("?"),
                  titles.insert(title).inserted else { return nil }
            return PlexLibraryFilterChoice(title: title, value: value)
        }.sorted {
            if field == .year { return $0.title.localizedStandardCompare($1.title) == .orderedDescending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func queryItems(genre: String?, year: String?, search: String) -> [URLQueryItem] {
        var result: [URLQueryItem] = []
        if let genre, !genre.isEmpty { result.append(URLQueryItem(name: "genre", value: genre)) }
        if let year, !year.isEmpty { result.append(URLQueryItem(name: "year", value: year)) }
        let title = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { result.append(URLQueryItem(name: "title", value: title)) }
        return result
    }
}
