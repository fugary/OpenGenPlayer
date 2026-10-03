import Foundation

@main
enum PlexLibraryFilterChecks {
    static func main() {
        let genres = PlexLibraryFilters.choices(from: [
            ["title": "Action", "key": "5"],
            ["title": "Comedy", "key": "/library/sections/1/all?genre=12"],
            ["title": "Drama", "key": "99", "fastKey": "/library/sections/1/all?genre=42&type=1"],
            ["title": "Comedy", "key": "13"],
            ["title": "Missing"],
            ["title": "Invalid", "key": "https://example.invalid/anything"],
            ["title": "Numeric", "key": 7],
            ["title": "Absolute", "key": "https://example.invalid/library/sections/1/genre/8"]
        ], field: .genre)
        precondition(genres.count == 5)
        precondition(genres.first(where: { $0.title == "Drama" })?.value == "42")
        precondition(genres.first(where: { $0.title == "Comedy" })?.value == "12")
        precondition(genres.first(where: { $0.title == "Numeric" })?.value == "7")
        precondition(genres.first(where: { $0.title == "Absolute" })?.value == "8")
        let years = PlexLibraryFilters.choices(from: [
            ["title": "1999", "key": "1999"], ["title": "2026", "key": "2026"]
        ], field: .year)
        precondition(years.map(\.value) == ["2026", "1999"])
        precondition(PlexLibraryFilters.queryItems(genre: nil, year: nil, search: "").isEmpty,
                     "Existing callers must retain the same unfiltered request")
        var components = URLComponents(string: "https://example.invalid/library/sections/1/all")!
        components.queryItems = PlexLibraryFilters.queryItems(genre: "5", year: "2026", search: "  A&B  ")
        let decoded = URLComponents(url: components.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(decoded.count == 3)
        precondition(decoded.first(where: { $0.name == "genre" })?.value == "5")
        precondition(decoded.first(where: { $0.name == "year" })?.value == "2026")
        precondition(decoded.first(where: { $0.name == "title" })?.value == "A&B",
                     "A search containing & must remain a single encoded value")
        print("Plex library filter checks passed (server IDs, relative/absolute keys, duplicate/invalid rows, years, combined search and default compatibility).")
    }
}
