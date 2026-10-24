import Foundation

/// `--fixtures detail` on the phone: every series title page has two seasons of six episodes, so a
/// season switch (and an AI search episode pick in season 2) can be driven offline. The shared
/// fixture source gives a fixture series one season (FixtureBrowseSource.fixtureVideos, which the
/// TV's tests count on); the phone adds its second season here, before DetailModel sees the meta.
/// A title opened bare (a harbor://detail link, an AI pick) gets the episode list and the name its
/// fixture row would have given it. Every other launch passes the meta through untouched.
///
/// The engine has no TMDB to read offline, so every fixture title also gets the TMDB extras (a
/// trailer, a Videos row, the cast, the facts), an awards body and a gallery from here; the page
/// uses them only while DetailModel has none of its own (UI tests open each of them).
@MainActor
enum PhoneDetailFixtures {
    /// FixtureBrowseSource.rows' titles, in its order ("s-3" is the fourth).
    private static let titles = ["Dune: Part Two", "Oppenheimer", "The Bear", "Severance", "Poor Things", "Shōgun", "Past Lives", "Fallout",
                                 "The Holdovers", "Anatomy of a Fall", "Civil War", "Ripley"]

    static var active: Bool { Fixtures.active && FixtureBrowseSource.withEpisodes }

    static func prepare(_ meta: Meta) -> Meta {
        guard active else { return meta }
        var out = meta
        if out.name.isEmpty, let last = out.id.split(separator: "-").last, let i = Int(last), titles.indices.contains(i) {
            out.name = titles[i]
            out.description = "A placeholder synopsis for \(titles[i]), long enough to wrap onto a second line."
        }
        guard out.type == "series" else { return out }
        var videos: [AnyJSON] = out.videos ?? FixtureBrowseSource.fixtureVideos(out.id)
        let hasSecond = videos.contains { $0["season"]?.number == 2 }
        if !hasSecond { videos += secondSeason(out.id) }
        out.videos = videos
        return out
    }

    private static func secondSeason(_ id: String) -> [AnyJSON] {
        (1...6).map { n -> AnyJSON in
            .object([
                "id": .string("\(id):2:\(n)"), "season": .number(2), "episode": .number(Double(n)),
                "name": .string("Chapter \(n)"), "released": .string("2025-02-0\(n)T00:00:00.000Z"),
                "overview": .string("A placeholder synopsis for chapter \(n) of the second season."),
            ])
        }
    }

    // MARK: TMDB extras, awards, gallery

    /// TMDB's lead trailer for the fixtures (Dune: Part Two's), so the trailer sheet has a clip to embed.
    static let trailerId = "Way9Dexny3w"

    static func extras(for meta: Meta) -> DetailModel.Extras? {
        guard active else { return nil }
        let cast: [[String: Any]] = [
            ["id": 1190668, "name": "Timothée Chalamet", "character": "Paul Atreides"],
            ["id": 505710, "name": "Zendaya", "character": "Chani"],
            ["id": 933238, "name": "Rebecca Ferguson", "character": "Lady Jessica"],
            ["id": 1373737, "name": "Florence Pugh", "character": "Princess Irulan"],
        ]
        let crew: [[String: Any]] = [
            ["label": "Directed by", "names": ["Denis Villeneuve"], "people": [["id": 137427, "name": "Denis Villeneuve"]]],
        ]
        let facts: [[String: Any]] = [
            ["label": "Status", "value": "Released"],
            ["label": "Original Language", "value": "English"],
            ["label": "Budget", "value": "$190,000,000"],
            ["label": "Revenue", "value": "$714,844,358"],
            ["label": "Production", "value": "Legendary Pictures"],
        ]
        let videos: [[String: Any]] = [
            ["ytId": trailerId, "name": "Official Trailer 3", "type": "Trailer"],
        ]
        let body: [String: Any] = [
            "kind": meta.type == "series" ? "tv" : "movie", "tmdbId": 693134, "imdbId": NSNull(),
            "tagline": "", "overview": "", "status": "Released", "genres": ["Science Fiction", "Adventure"],
            "cast": cast, "crew": crew, "recommendations": [], "similar": [],
            "trailerYtId": trailerId, "facts": facts, "watchOn": [], "videos": videos,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(DetailModel.Extras.self, from: data)
    }

    static func awards() -> DetailModel.TitleAwards? {
        guard active else { return nil }
        typealias Entry = DetailModel.TitleAwards.Entry
        func oscar(_ category: String, _ result: String, _ recipient: String? = nil) -> Entry {
            Entry(type: "oscar", awardName: "Academy Awards", category: category, year: 2025, result: result, recipient: recipient)
        }
        return DetailModel.TitleAwards(
            groups: [.init(type: "oscar", title: "The Oscars", wins: 2, nominations: 3)],
            entries: [
                oscar("Best Sound", "won"),
                oscar("Best Visual Effects", "won"),
                oscar("Best Picture", "nominated"),
                oscar("Best Cinematography", "nominated", "Greig Fraser"),
                oscar("Best Production Design", "nominated"),
            ])
    }

    /// Placeholder art the gallery draws as numbered plates (PhoneGalleryArt), no network.
    static func gallery() -> PhoneGallery? {
        guard active else { return nil }
        return PhoneGallery(backdrops: (1...5).map { "fixture:backdrop-\($0)" },
                            posters: (1...3).map { "fixture:poster-\($0)" },
                            logos: [])
    }
}
