import SwiftUI

/// The person page (the TV's PersonView, bp-person.tsx) over the shared `PersonModel`: a large
/// portrait over its own blurred art, the department with its "Top {n}" pill, facts, awards and the
/// biography with Read more; then Known For, IMDb Top, Frequent Collaborators, and the filmography
/// with the TV's Sort and Rating chips and its sections as rails. Every title opens through `open`;
/// a collaborator pushes their own page on the tab's path (`PhoneRoute.person`), so a title opened
/// from it pushes above it and Back comes down through both.
struct PhonePersonPage: View {
    @StateObject private var model: PersonModel
    /// The tab's stack (the page only ever opens inside a `PhoneTabStack`).
    @EnvironmentObject private var nav: PhoneNavigator
    let name: String
    let open: (Meta) -> Void

    @State private var bioExpanded = false
    /// Heights of the biography at four lines and in full: Read more shows only when they differ,
    /// so a short bio has no toggle and a long one (or any at a large text size) always does.
    @State private var bioClampedHeight: CGFloat = 0
    @State private var bioFullHeight: CGFloat = 0
    /// The page under `--fixtures`, where the engine has no TMDB to read.
    @State private var fixture: PersonModel.Page?
    /// The name moves into the navigation bar once the header's has scrolled away.
    @State private var titleShown = false
    @ScaledMetric(relativeTo: .title) private var portraitWidth: CGFloat = 164

    init(personId: Int, name: String, open: @escaping (Meta) -> Void) {
        _model = StateObject(wrappedValue: PersonModel(personId: personId))
        self.name = name
        self.open = open
    }

    private var offline: Bool { Fixtures.active && !Fixtures.liveRooms }
    private var page: PersonModel.Page? { offline ? fixture : model.page }
    private var loading: Bool { offline ? fixture == nil : model.loading }
    private var person: PersonModel.Person? { page?.person }
    private var displayName: String { person?.name ?? name }
    /// The portrait at a size that stays sharp at the header's width (the engine hands w342).
    private var portraitURL: String? {
        person?.portrait.map { $0.replacingOccurrences(of: "/t/p/w342/", with: "/t/p/h632/") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if let page {
                    content(page)
                } else if loading {
                    skeleton
                } else {
                    // The TV's failed-load card: the name stays, with Try again.
                    ErrorPlate(title: T("Something went wrong. Try again.")) { Task { await model.load() } }
                }
            }
            .padding(.bottom, 36)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > 300
        } action: { _, shown in
            withMotion(.easeOut(duration: 0.18)) { titleShown = shown }
        }
        .background(PhoneBackground())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: displayName)
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                    .opacity(titleShown ? 1 : 0)
                    .accessibilityHidden(!titleShown)
            }
        }
        // Read once: coming back from a title or a collaborator keeps the page as it was
        // (harbor:person-updated still refreshes it, inside PersonModel).
        .task {
            if offline {
                if fixture == nil { fixture = Self.fixturePage(name: name, sort: model.sort, minRating: model.minRating) }
                return
            }
            guard model.page == nil else { return }
            await model.load()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("person-page")
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            portrait
            VStack(spacing: 8) {
                if let person, !person.department.isEmpty || person.topLabel != nil { eyebrow(person) }
                Text(verbatim: displayName)
                    .font(PhoneTheme.display(34, .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(BP.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("person-name")
                if let person {
                    let factLine: String = person.facts.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !factLine.isEmpty {
                        Text(verbatim: factLine)
                            .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                            .foregroundStyle(BP.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                }
                if let awards = page?.awards, !awards.isEmpty {
                    Text(verbatim: awards.prefix(4).map(Self.awardLine).joined(separator: " · "))
                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                        .foregroundStyle(BP.inkSubtle)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            if let bio = person?.biography, !bio.isEmpty { biography(bio) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .background(alignment: .top) { backdrop }
    }

    /// The portrait again, blurred wide behind the header and under the bar, fading into the canvas.
    @ViewBuilder private var backdrop: some View {
        if let portraitURL {
            PhoneImage(url: portraitURL, plate: false, decodeScale: 0.25)
                .frame(height: 380)
                .blur(radius: 48, opaque: true)
                .opacity(0.55)
                .overlay(LinearGradient(colors: [BP.canvas.opacity(0), BP.canvas], startPoint: .center, endPoint: .bottom))
                .clipped()
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var portrait: some View {
        let width: CGFloat = min(portraitWidth, 240)
        return ZStack {
            BP.ink.opacity(0.07)
            if let portraitURL {
                PhoneImage(url: portraitURL)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: width * 0.34))
                    .foregroundStyle(BP.inkSubtle)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous).stroke(BP.ink.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        // bp-person.tsx portrait alt="": the name under it names the person.
        .accessibilityHidden(true)
    }

    /// bp-person.tsx: the department as the eyebrow, then "Top {n}" as a quiet glass pill. One
    /// VoiceOver stop, as on the TV.
    private func eyebrow(_ p: PersonModel.Person) -> some View {
        HStack(spacing: 10) {
            if !p.department.isEmpty {
                Text(verbatim: p.department)
                    .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(1.6)
                    .foregroundStyle(BP.inkSubtle)
            }
            if let top = p.topLabel {
                Text(verbatim: top)
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .monospacedDigit()
                    .foregroundStyle(BP.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.tint(BP.accent.opacity(0.35)), in: .capsule)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The biography, four lines until Read more opens the rest. Read more shows when the four lines
    /// actually cut the text, measured against a hidden full copy at the same width and text size.
    private func biography(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            bioText(bio)
                .lineLimit(bioExpanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !bioExpanded { bioClampedHeight = height }
                }
                .background(alignment: .topLeading) {
                    bioText(bio)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bioFullHeight = $0 }
                }
                .accessibilityIdentifier("person-bio")
            if bioExpanded || bioFullHeight > bioClampedHeight + 1 {
                Button {
                    PhoneFeedback.shared.tap()
                    withMotion(.snappy) { bioExpanded.toggle() }
                } label: {
                    Text(verbatim: T(bioExpanded ? "Show less" : "Read more"))
                        .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("person-bio-more")
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    private func bioText(_ bio: String) -> some View {
        Text(verbatim: bio)
            .font(PhoneTheme.sans(15, .regular, relativeTo: .body))
            .foregroundStyle(BP.inkMuted)
            .lineSpacing(3)
    }

    // MARK: Content

    @ViewBuilder private func content(_ pg: PersonModel.Page) -> some View {
        // bp-person.tsx's no-key BpEmptyState copy.
        if !pg.hasKey { note(T("Filmographies come from TMDB. Add a key in Setup to fill this page.")) }
        if let k = pg.knownFor, !k.isEmpty { titleRail(T("Known For"), key: "knownFor", metas: k) }
        if let t = pg.topRated, !t.isEmpty { titleRail(T("IMDb Top"), key: "topRated", metas: t) }
        if let c = pg.collaborators, c.count >= 3 { collaborators(c) }
        // bp-person.tsx: the Filmography heading and the Sort / Rating rows stand while the person
        // has any credit, so a Rating pick no title clears can be taken back.
        if (pg.total ?? 0) > 0 { filmographyControls(pg) }
        ForEach(pg.sections ?? []) { s in titleRail(s.title, key: "film:\(s.id)", metas: s.metas) }
        if pg.hasKey, !loading, (pg.shownTotal ?? 0) == 0 {
            if (pg.total ?? 0) > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    note(T("No titles clear that rating."))
                    Button(T("Any rating")) { pick(minRating: 0) }
                        .buttonStyle(.glassProminent)
                        .padding(.horizontal, PhoneTheme.margin)
                        .accessibilityIdentifier("person-any-rating")
                }
            } else {
                note(T("No filmography on record."))
            }
        }
    }

    private func titleRail(_ title: String, key: String, metas: [Meta]) -> some View {
        Rail(title, identifier: key) {
            ForEach(metas) { meta in
                PosterTile(meta: meta) { open(meta) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
            .foregroundStyle(BP.inkMuted)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.ink.opacity(0.06)))
            .padding(.horizontal, PhoneTheme.margin)
            .accessibilityIdentifier("person-note")
    }

    /// bp-collaborators: round portraits with the shared-title count and role; one opens that person.
    private func collaborators(_ people: [PersonModel.Collaborator]) -> some View {
        Rail(T("Frequent Collaborators"), identifier: "collaborators") {
            ForEach(people.prefix(18)) { c in
                Button {
                    nav.push(PhoneRoute.person(id: c.id, name: c.name))
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            PhoneImage(url: c.portrait)
                            if c.portrait == nil {
                                Image(systemName: "person.fill")
                                    .font(.title2)
                                    .foregroundStyle(BP.inkMuted)
                            }
                        }
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                        Text(verbatim: c.name)
                            .font(PhoneTheme.sans(13, .semibold, relativeTo: .caption))
                            .foregroundStyle(BP.ink)
                            .lines(1)
                        Text(verbatim: collaboratorLine(c))
                            .font(PhoneTheme.sans(11, .regular, relativeTo: .caption2))
                            .foregroundStyle(BP.inkSubtle)
                            .lines(1)
                    }
                    .frame(width: 100)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(c.name), \(collaboratorLine(c))"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("collaborator-\(c.id)")
            }
        }
    }

    private func collaboratorLine(_ c: PersonModel.Collaborator) -> String {
        TCount(c.titles, one: "%lld title", "%lld titles") + (c.role.map { " · " + T($0) } ?? "")
    }

    /// The Filmography heading, the "{shown} of {total}" count, then the Sort and Rating chips and
    /// the caption on why a well-known title can drop out (filmography-rank.ts MIN_VOTES_*).
    private func filmographyControls(_ pg: PersonModel.Page) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: T("Filmography"))
                    .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(verbatim: T("%lld of %lld", pg.shownTotal ?? 0, pg.total ?? 0))
                    .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                    .monospacedDigit()
                    .foregroundStyle(BP.inkSubtle)
                    .accessibilityIdentifier("person-count")
            }
            .padding(.horizontal, PhoneTheme.margin)
            chipRow(T("Sort"), [("popularity", T("Popularity")), ("rating", T("Rating")), ("newest", T("Newest"))],
                    active: model.sort) { pick(sort: $0) }
            chipRow(T("Rating"), [("0", T("Any rating")), ("6", T("Rated %lld+", 6)), ("7", T("Rated %lld+", 7)), ("8", T("Rated %lld+", 8))],
                    active: String(model.minRating)) { pick(minRating: Int($0) ?? 0) }
            Text(verbatim: T("Ratings count from %lld+ votes, %lld+ for TV", 200, 100))
                .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                .foregroundStyle(BP.inkSubtle)
                .padding(.horizontal, PhoneTheme.margin)
        }
    }

    /// A heading and its chips; the row scrolls the selected chip into view when it appears and after
    /// each pick, so the active Sort or Rating never sits past the edge.
    private func chipRow(_ heading: String, _ options: [(String, String)], active: String, pick: @escaping (String) -> Void) -> some View {
        ScrollViewReader { proxy in
            ChipRow {
                Text(verbatim: heading.uppercased())
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                    .tracking(1.4)
                    .foregroundStyle(BP.inkSubtle)
                    .accessibilityHidden(true)
                ForEach(options, id: \.0) { option in
                    GlassChip(title: option.1, selected: active == option.0) {
                        guard active != option.0 else { return }
                        pick(option.0)
                    }
                    .accessibilityHint(Text(verbatim: heading))
                    .id(option.0)
                }
            }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo(active, anchor: .center) }
            }
            .onChange(of: active) { _, selected in
                withMotion(.snappy) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    /// A Sort or Rating chip: the newest read wins inside PersonModel; under fixtures the page is
    /// re-cut here.
    private func pick(sort: String? = nil, minRating: Int? = nil) {
        PhoneFeedback.shared.selection()
        if let sort { model.sort = sort }
        if let minRating { model.minRating = minRating }
        if offline {
            fixture = Self.fixturePage(name: name, sort: model.sort, minRating: model.minRating)
        } else {
            Task { await model.load() }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(width: 140, height: 20)
                        .padding(.horizontal, PhoneTheme.margin)
                    HStack(spacing: PhoneTheme.railGap) {
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonBlock(width: PhoneTheme.posterWidth, height: PhoneTheme.posterWidth * 1.5)
                        }
                    }
                    .padding(.horizontal, PhoneTheme.margin)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: T("Loading…")))
        .accessibilityIdentifier("person-loading")
    }

    /// bp-person.tsx BpPersonAwards: "{n} win(s)" (else "{n} nom(s)"), then the nominations beside a
    /// win, under the award body (a proper noun, left untranslated like upstream).
    private static func awardLine(_ a: PersonModel.Award) -> String {
        let noms = a.nominations == 1 ? T("%lld nom", a.nominations) : T("%lld noms", a.nominations)
        let headline = a.wins > 0 ? (a.wins == 1 ? T("%lld win", a.wins) : T("%lld wins", a.wins)) : noms
        let body: String = a.shorthand ?? T("Award")
        return "\(body): \(headline)" + (a.wins > 0 && a.nominations > 0 ? ", \(noms)" : "")
    }

    // MARK: Fixtures

    /// A person for `--fixtures`: the facts, an award, Known For, IMDb Top, three collaborators and
    /// two filmography sections, cut by Sort and Rating the way the engine cuts them.
    static func fixturePage(name: String, sort: String, minRating: Int) -> PersonModel.Page? {
        func meta(_ id: String, _ type: String, _ title: String, _ year: String, _ rating: String) -> [String: Any] {
            ["id": id, "type": type, "name": title, "releaseInfo": year, "imdbRating": rating,
             "description": "A placeholder synopsis for \(title)."]
        }
        let movies: [[String: Any]] = [
            meta("fx-person-m-0", "movie", "Dune: Part Two", "2024", "8.5"),
            meta("fx-person-m-1", "movie", "Wonka", "2023", "7.1"),
            meta("fx-person-m-2", "movie", "Little Women", "2019", "7.8"),
            meta("fx-person-m-3", "movie", "Call Me by Your Name", "2017", "7.8"),
        ]
        let shows: [[String: Any]] = [meta("fx-person-s-0", "series", "Homeland", "2011", "8.3")]
        func rating(_ m: [String: Any]) -> Double { Double(m["imdbRating"] as? String ?? "") ?? 0 }
        func cut(_ list: [[String: Any]]) -> [[String: Any]] {
            let kept = list.filter { rating($0) >= Double(minRating) }
            switch sort {
            case "rating": return kept.sorted { rating($0) > rating($1) }
            case "newest": return kept.sorted { ($0["releaseInfo"] as? String ?? "") > ($1["releaseInfo"] as? String ?? "") }
            default: return kept
            }
        }
        let shownMovies = cut(movies)
        let shownShows = cut(shows)
        var sections: [[String: Any]] = []
        if !shownMovies.isEmpty { sections.append(["id": "movies", "title": "Movies · \(shownMovies.count)", "metas": shownMovies]) }
        if !shownShows.isEmpty { sections.append(["id": "shows", "title": "TV Shows · \(shownShows.count)", "metas": shownShows]) }
        let bio: String = "A placeholder biography. \(name) grew up between two cities and started acting on stage in school, "
            + "then in television, before a string of films made the name known. The roles since have ranged from "
            + "quiet dramas to the largest science-fiction epics of the decade, often with the same directors twice. "
            + "Away from the set, the work goes on in theatre and in music."
        let person: [String: Any] = [
            "id": 1190668, "name": name, "department": "Acting", "biography": bio,
            "facts": ["Born Dec 27, 1995 · 30", "New York City, New York, USA"],
            "deptRank": 12, "topLabel": "Top 12",
        ]
        let collaborators: [[String: Any]] = [
            ["id": 137427, "name": "Denis Villeneuve", "role": "Director", "titles": 2],
            ["id": 505710, "name": "Zendaya", "titles": 2],
            ["id": 45400, "name": "Greta Gerwig", "role": "Director", "titles": 2],
        ]
        let awards: [[String: Any]] = [["type": "oscar", "wins": 0, "nominations": 1, "shorthand": "The Oscars"]]
        let body: [String: Any] = [
            "hasKey": true, "person": person,
            "knownFor": Array(movies.prefix(3)), "topRated": [movies[0], shows[0]],
            "collaborators": collaborators, "awards": awards, "sections": sections,
            "total": movies.count + shows.count, "shownTotal": shownMovies.count + shownShows.count,
            "sort": sort, "minRating": minRating,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(PersonModel.Page.self, from: data)
    }
}
