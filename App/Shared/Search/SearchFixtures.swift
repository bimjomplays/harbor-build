import Foundation

/// Fake search answers for the simulator (`--fixtures shell`): SearchModel and AISearchModel take
/// these instead of calling the engine, so a UI test can type a query and read grouped results
/// without the network. `--fixtures live` keeps the real engine. A query containing "nothing"
/// finds nothing, for the empty state.
extension SearchModel {
    @MainActor static var usesFixtures: Bool { Fixtures.active && !Fixtures.liveRooms }

    /// Movies, Shows, Anime, a person and one addon, whatever the query.
    @MainActor static func fixtureResults(_ query: String) throws -> Results {
        let empty: Bool = query.lowercased().contains("nothing")
        func meta(_ id: String, _ type: String, _ name: String, _ year: String) -> [String: Any] {
            ["id": id, "type": type, "name": name, "releaseInfo": year, "imdbRating": "8.1",
             "description": "A placeholder synopsis for \(name)."]
        }
        let movies: [[String: Any]] = empty ? [] : [
            meta("fx-search-m-0", "movie", "Dune: Part Two", "2024"),
            meta("fx-search-m-1", "movie", "Dune", "2021"),
            meta("fx-search-m-2", "movie", "Dune", "1984"),
        ]
        let series: [[String: Any]] = empty ? [] : [
            meta("fx-search-s-0", "series", "Dune: Prophecy", "2024"),
            meta("fx-search-s-1", "series", "Severance", "2022"),
        ]
        let anime: [[String: Any]] = empty ? [] : [
            ["name": "Sand Planet Chronicles", "kitsuId": 4242, "year": "2019", "overview": "A placeholder anime."],
        ]
        let people: [[String: Any]] = empty ? [] : [
            ["id": 1190668, "name": "Timothée Chalamet", "knownFor": "Dune: Part Two"],
        ]
        let addonMetas: [[String: Any]] = empty ? [] : [meta("fx-search-a-0", "movie", "Dune: Addon Cut", "2024")]
        let addonGroup: [String: Any] = ["id": "fx-addon", "name": "Fixture Addon", "metas": addonMetas, "state": addonMetas.isEmpty ? "empty" : "ok"]
        let body: [String: Any] = [
            "query": query, "movies": movies, "series": series, "anime": anime, "people": people,
            "addonQueries": [addonGroup], "addonGroups": [addonGroup],
        ]
        let data: Data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(Results.self, from: data)
    }
}

extension AISearchModel {
    /// A model with a key on file, so the AI section shows its picks.
    static func fixtureState() -> State? {
        let body: [String: Any] = [
            "tab": "openrouter", "model": "fixture/model", "label": "Fixture model", "provider": "openrouter",
            "providerName": "Fixture", "anyKey": true, "hasKey": true, "saved": [String: Any](), "webSearch": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// One title and one episode pick.
    static func fixtureResults() -> [Result] {
        let body: [[String: Any]] = [
            ["meta": ["id": "fx-ai-0", "type": "movie", "name": "Dune: Part Two", "releaseInfo": "2024", "imdbRating": "8.5",
                      "description": "A placeholder synopsis for the first AI pick."]],
            ["meta": ["id": "fx-ai-1", "type": "series", "name": "Severance", "releaseInfo": "2022", "imdbRating": "8.7"],
             "season": 2, "episode": 4, "episodeTitle": "Woe's Hollow"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        return (try? JSONDecoder().decode([Result].self, from: data)) ?? []
    }
}
