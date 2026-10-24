import Foundation

/// The Library under `--fixtures` (no engine): a small library in every core tab, made from the
/// fixture catalog's titles, and a year of Stats for the Wrapped story. UI tests read these names.
enum PhoneLibraryFixtures {
    static let tabs: [LibraryModel.Tab] = [
        LibraryModel.Tab(id: "library", label: "Saved"), LibraryModel.Tab(id: "watchlist", label: "Watchlist"),
        LibraryModel.Tab(id: "history", label: "History"), LibraryModel.Tab(id: "lists", label: "My Lists"),
        LibraryModel.Tab(id: "favorites", label: "Favorites"),
    ]

    static let listGroups: [LibraryModel.Group] = [LibraryModel.Group(id: "weekend", label: "Weekend", count: nil)]

    private static let now = Date().timeIntervalSince1970 * 1000
    private static let day: Double = 86_400_000

    static func meta(_ id: String, _ type: String, _ name: String, _ year: String) -> Meta {
        Meta(id: id, type: type, name: name, poster: nil, background: nil, logo: nil,
             description: "A placeholder synopsis for \(name).", releaseInfo: year, releaseDate: nil, inTheaters: nil,
             imdbRating: "8.1", tmdbScore: 7.5, runtime: type == "movie" ? "2h 6m" : nil, genres: ["Drama"],
             adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
    }

    private static func entry(_ meta: Meta, daysAgo: Double, key: String? = nil, group: String? = nil,
                              progress: Double? = nil, watched: Bool? = nil) -> LibraryModel.Entry {
        LibraryModel.Entry(key: key ?? meta.id, meta: meta, date: now - daysAgo * day, group: group,
                           progress: progress, season: nil, episode: nil, watched: watched)
    }

    static let dune = meta("lib-dune", "movie", "Dune: Part Two", "2024")
    static let poorThings = meta("lib-poor-things", "movie", "Poor Things", "2023")
    static let pastLives = meta("lib-past-lives", "movie", "Past Lives", "2022")
    static let bear = meta("lib-bear", "series", "The Bear", "2021")
    static let oppenheimer = meta("lib-oppenheimer", "movie", "Oppenheimer", "2023")
    static let shogun = meta("lib-shogun", "series", "Shōgun", "2024")
    static let fallout = meta("lib-fallout", "series", "Fallout", "2024")
    static let holdovers = meta("lib-holdovers", "movie", "The Holdovers", "2023")
    static let ripley = meta("lib-ripley", "series", "Ripley", "2024")
    static let anatomy = meta("lib-anatomy", "movie", "Anatomy of a Fall", "2023")
    static let civilWar = meta("lib-civil-war", "movie", "Civil War", "2024")
    static let severance = meta("lib-severance", "series", "Severance", "2022")

    /// One engine tab's entries. Saved, newest first: Past Lives, The Bear, Dune: Part Two, Poor
    /// Things. History: The Holdovers and Ripley in progress; Anatomy of a Fall, Civil War and
    /// Severance watched.
    static func entries(tab: String) -> [LibraryModel.Entry] {
        switch tab {
        case "library":
            return [entry(pastLives, daysAgo: 1), entry(bear, daysAgo: 3), entry(dune, daysAgo: 6), entry(poorThings, daysAgo: 12)]
        case "watchlist":
            return [entry(oppenheimer, daysAgo: 2), entry(shogun, daysAgo: 4), entry(fallout, daysAgo: 9)]
        case "history":
            return [entry(holdovers, daysAgo: 0.2, progress: 0.42, watched: false),
                    entry(ripley, daysAgo: 1.5, progress: 0.6, watched: false),
                    entry(anatomy, daysAgo: 5, progress: 1, watched: true),
                    entry(civilWar, daysAgo: 8),
                    entry(severance, daysAgo: 14, progress: 0, watched: false)]
        case "lists":
            return [entry(dune, daysAgo: 2, key: "weekend:lib-dune", group: "weekend"),
                    entry(shogun, daysAgo: 3, key: "weekend:lib-shogun", group: "weekend")]
        case "favorites":
            return [entry(poorThings, daysAgo: 20)]
        default:
            return []
        }
    }

    /// A year of Stats: every card of the story has something to draw.
    static var stats: WrappedModel.Stats {
        let top: [WrappedModel.TopTitle] = [
            WrappedModel.TopTitle(title: severance.name, count: 19, imdb: nil, id: severance.id, type: "series"),
            WrappedModel.TopTitle(title: bear.name, count: 18, imdb: nil, id: bear.id, type: "series"),
            WrappedModel.TopTitle(title: shogun.name, count: 10, imdb: nil, id: shogun.id, type: "series"),
            WrappedModel.TopTitle(title: dune.name, count: 2, imdb: nil, id: dune.id, type: "movie"),
            WrappedModel.TopTitle(title: pastLives.name, count: 1, imdb: nil, id: pastLives.id, type: "movie"),
        ]
        // 53 weeks of 7 days, a steady pattern with heavier weekends.
        let weeks: [[WrappedModel.HeatDay]] = (0..<53).map { w in
            (0..<7).map { d in
                let level: Int = heatLevel(week: w, day: d)
                return WrappedModel.HeatDay(key: "w\(w)d\(d)", count: level, level: level)
            }
        }
        return WrappedModel.Stats(
            source: "trakt", year: 2026, totalTitles: 48, totalPlays: 131, estimatedHours: 212,
            topTitles: top,
            topGenres: [WrappedModel.Genre(genre: "Drama", count: 18), WrappedModel.Genre(genre: "Thriller", count: 11),
                        WrappedModel.Genre(genre: "Comedy", count: 7), WrappedModel.Genre(genre: "Science Fiction", count: 5)],
            topActors: [WrappedModel.Actor(name: "Adam Scott", count: 3, photo: nil), WrappedModel.Actor(name: "Ayo Edebiri", count: 2, photo: nil),
                        WrappedModel.Actor(name: "Hiroyuki Sanada", count: 2, photo: nil), WrappedModel.Actor(name: "Zendaya", count: 2, photo: nil)],
            posters: [:],
            split: WrappedModel.Split(movies: 29, series: 15, anime: 4),
            firstPlay: WrappedModel.Play(id: dune.id, title: dune.name, type: "movie", watchedAt: now - 280 * day),
            lastPlay: WrappedModel.Play(id: holdovers.id, title: holdovers.name, type: "movie", watchedAt: now - 0.2 * day),
            longestBinge: WrappedModel.Binge(date: "2026-03-14", count: 6),
            archetype: WrappedModel.Archetype(id: "weekender", label: "The Weekender", blurb: "Most of your watching lands on Saturdays and Sundays."),
            heatWeeks: weeks,
            bingeDate: "March 14")
    }

    private static func heatLevel(week w: Int, day d: Int) -> Int {
        if (w * 3 + d * 5) % 7 == 0 { return 4 }
        if d >= 5 { return 3 }
        if (w + d) % 4 == 0 { return 2 }
        return (w + d) % 3 == 0 ? 1 : 0
    }
}
