import SwiftUI

/// Discover: a hero band, the Discovery Queue entry card, the daily
/// shelves, the award strips, the Voyage banner and the genre grid. It reads the same `DiscoverModel`
/// the TV does (engine/discover.ts), so what the phone shows is what the engine built for this
/// profile. The queue, an award, Voyage and a genre push onto the tab's navigation stack; a title
/// opens through `open`, which the shell turns into the title page.
///
/// Under `--fixtures` the engine has no TMDB, so the screen draws its own offline content from the
/// fixture browse source instead (except `discfail`, which keeps the real failure to drive Try again).
struct PhoneDiscoverView: View {
    let open: (Meta) -> Void

    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var model = DiscoverModel()
    /// The tab's stack: the queue, an award, Voyage and a genre push there.
    @EnvironmentObject private var nav: PhoneNavigator
    /// A Route page is on the stack: back from it, the queue card and the Voyage banner reload.
    @State private var routeOpen = false
    @State private var fixtureRows: [BrowseRow] = []
    @State private var fixtureReady = false

    enum Route: Hashable {
        case queue
        case award(String)
        case animeAward(String)
        case voyage
        case genre(String)
    }

    private enum Phase {
        case loading
        case failed(String)
        case ready
    }

    // MARK: Data (live from the model, or the offline fixtures)

    private var offline: Bool { Fixtures.active && !Fixtures.liveRooms && !FixtureBrowseSource.failDiscover }

    private var phase: Phase {
        if offline { return fixtureReady ? .ready : .loading }
        if model.build != nil { return .ready }
        if let failed = model.failed { return .failed(failed) }
        return .loading
    }

    private var rows: [BrowseRow] {
        let all: [BrowseRow] = offline ? fixtureRows : model.rows
        return all.filter { !$0.metas.isEmpty }
    }

    private var genres: [DiscoverModel.Build.Genre] {
        offline ? PhoneDiscoverFixtures.genres : (model.build?.genres ?? [])
    }

    private var awards: [DiscoverModel.Awards.Summary] {
        offline ? PhoneDiscoverFixtures.awards : (model.awards?.summaries ?? [])
    }

    private var animeAwards: [DiscoverModel.AnimeAwardTile] {
        offline ? PhoneDiscoverFixtures.animeAwards : model.animeAwards
    }

    /// One lead title per shelf, so the band opens on variety rather than on one shelf's first five.
    private var heroItems: [Meta] {
        var seen = Set<String>()
        var out: [Meta] = []
        for row in rows {
            for meta in row.metas where !seen.contains(meta.id) {
                seen.insert(meta.id)
                out.append(meta)
                break
            }
            if out.count == 6 { break }
        }
        return out
    }

    private var queueInfo: (status: String, total: Int, posters: [String], backdrop: String?) {
        if offline { return ("ready", PhoneQueueModel.fixtureDeck().count, [], nil) }
        guard let queue = model.build?.queue else { return ("loading", 0, [], nil) }
        return (queue.status, queue.total, queue.posters, queue.backdrop)
    }

    /// discover.tsx voyageBannerPool: the banner shows once the pool holds three titles, or a voyage is under way.
    private var showsVoyage: Bool {
        if offline { return true }
        if model.voyage?.active != nil { return true }
        return (model.build?.voyagePool?.count ?? 0) >= 3
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                switch phase {
                case .loading:
                    skeleton
                case .failed(let message):
                    ErrorPlate(title: T("Couldn't load this"), message: message) {
                        Task { await load() }
                    }
                    .padding(.top, 24)
                case .ready:
                    content
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await model.reloadQueue() }
        .task { await load() }
        .navigationDestination(for: Route.self) { target in
            destination(target)
        }
        .onChange(of: nav.path.isEmpty) { _, empty in
            guard empty, routeOpen else { return }
            routeOpen = false
            // Back from the queue or a voyage: the card and the banner read what changed there.
            Task {
                await model.reloadQueue()
                await model.loadVoyage()
            }
        }
        .accessibilityIdentifier("discover")
    }

    @ViewBuilder private var content: some View {
        let lead: [Meta] = heroItems
        if !lead.isEmpty { HeroCarousel(items: lead, open: open) }
        PhoneQueueEntryCard(status: queueInfo.status, total: queueInfo.total,
                            posters: queueInfo.posters, backdrop: queueInfo.backdrop) {
            go(.queue)
        }
        ForEach(rows) { row in
            Rail(row.title) {
                ForEach(row.metas) { meta in
                    PosterTile(meta: meta) { open(meta) }
                }
            }
        }
        if !awards.isEmpty || !animeAwards.isEmpty { awardsBand }
        if showsVoyage {
            PhoneVoyageBanner(snapshot: offline ? nil : model.voyage) { go(.voyage) }
        }
        if !genres.isEmpty { genreBand }
    }

    private func go(_ target: Route) {
        routeOpen = true
        nav.push(target)
    }

    private func destination(_ target: Route) -> some View {
        Group {
            switch target {
            case .queue:
                PhoneQueueView(open: open)
            case .award(let type):
                if let summary = awards.first(where: { $0.type == type }) {
                    PhoneAwardPage(summary: summary, open: open)
                } else {
                    EmptyState(title: T("Awards"), message: T("This award isn't available right now."), systemImage: "trophy")
                }
            case .animeAward(let id):
                PhoneAnimeAwardPage(sources: animeAwards, initial: id, open: open)
            case .voyage:
                PhoneVoyagePage(open: open)
            case .genre(let name):
                PhoneGenrePage(genre: name, offline: offline, open: open)
            }
        }
        .background(PhoneBackground())
    }

    // MARK: Bands

    private var awardsBand: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: T("Awards"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: PhoneTheme.railGap) {
                    ForEach(awards) { summary in
                        PhoneAwardTile(title: summary.shorthand,
                                       subtitle: TCount(summary.wins, one: "%lld winner", "%lld winners"),
                                       detail: summary.span,
                                       tint: PhoneTint.color(summary.tint),
                                       identifier: "award-\(summary.type)") {
                            go(.award(summary.type))
                        }
                    }
                    ForEach(animeAwards) { tile in
                        PhoneAwardTile(title: tile.shortName,
                                       subtitle: TCount(tile.wins, one: "%lld winner", "%lld winners"),
                                       detail: tile.name,
                                       tint: BP.accent,
                                       identifier: "anime-award-\(tile.id)") {
                            go(.animeAward(tile.id))
                        }
                    }
                }
                .padding(.horizontal, PhoneTheme.margin)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover-awards")
    }

    private var genreBand: some View {
        // One column at accessibility text sizes: a genre name does not fit half a phone there.
        let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: PhoneTheme.railGap),
                                        count: typeSize.isAccessibilitySize ? 1 : 2)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: T("Genres"))
            LazyVGrid(columns: columns, spacing: PhoneTheme.railGap) {
                PhoneSurpriseTile {
                    guard let pick = genres.randomElement() else { return }
                    go(.genre(pick.genre))
                }
                ForEach(genres, id: \.genre) { genre in
                    PhoneGenreTile(genre: genre, art: model.genreArt[genre.genre] ?? []) {
                        go(.genre(genre.genre))
                    }
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            // Each genre's backdrops are fetched once the band is reached, as the TV does.
            .task { if !offline { await model.loadGenreArt() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover-genres")
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            SkeletonBlock(height: 400, radius: PhoneTheme.radiusLarge)
                .padding(.horizontal, PhoneTheme.margin)
            SkeletonBlock(height: 170, radius: PhoneTheme.radiusLarge)
                .padding(.horizontal, PhoneTheme.margin)
            HStack(spacing: PhoneTheme.railGap) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonBlock(width: PhoneTheme.posterWidth, height: PhoneTheme.posterWidth * 1.5)
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
        }
        .accessibilityIdentifier("discover-loading")
    }

    // MARK: Loading

    private func load() async {
        if offline {
            let source = app.browseSource
            let found: [BrowseRow] = (try? await source.rows(for: .home)) ?? []
            guard !Task.isCancelled else { return }
            fixtureRows = Array(found.prefix(3))
            fixtureReady = true
            return
        }
        await model.load()
    }
}

// MARK: Parts

/// The colour of a tint the engine names in oklch or CSS.
enum PhoneTint {
    static func color(_ text: String) -> Color {
        Color(oklch: text) ?? Color(css: text) ?? BP.accent
    }
}

/// The Discovery Queue card: the first pick's backdrop with the next posters fanned over it, how
/// many picks wait, and a way in.
private struct PhoneQueueEntryCard: View {
    let status: String
    let total: Int
    let posters: [String]
    let backdrop: String?
    let action: () -> Void

    private var line: String {
        if total > 0 { return TCount(total, one: "%lld pick tonight", "%lld picks tonight") }
        switch status {
        case "nokey": return T("Add a TMDB key in Settings to unlock the full discovery feed.")
        case "unreachable": return T("No picks loaded. TMDB might be unreachable.")
        case "loading": return T("Building tonight's queue…")
        default: return T("Come back tomorrow for fresh picks.")
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                PhoneImage(url: backdrop ?? posters.first)
                LinearGradient(colors: [BP.accent.opacity(0.35), BP.canvas.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                HStack(spacing: -34) {
                    Spacer(minLength: 0)
                    ForEach(Array(posters.prefix(3).enumerated()), id: \.offset) { i, url in
                        PhoneImage(url: url)
                            .frame(width: 78, height: 117)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .rotationEffect(.degrees(Double(i - 1) * 7))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    }
                }
                .padding(.trailing, 28)
                .padding(.bottom, 52)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: T("Discovery Queue"))
                        .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
                        .textCase(.uppercase)
                        .foregroundStyle(BP.accent)
                    Text(verbatim: line)
                        .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                        .foregroundStyle(BP.ink)
                        .multilineTextAlignment(.leading)
                        .lines(2)
                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw.fill").accessibilityHidden(true)
                        Text(verbatim: T("Swipe through them"))
                    }
                    .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(BP.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                }
                .padding(PhoneTheme.margin)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous))
            .padding(.horizontal, PhoneTheme.margin)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(T("Discovery Queue")), \(line)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("discover-queue-card")
    }
}

/// One awards body (or anime award source): its mark on its tint, the wins it holds, its span.
private struct PhoneAwardTile: View {
    let title: String
    let subtitle: String
    let detail: String
    let tint: Color
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(verbatim: title)
                    .font(PhoneTheme.display(20, .semibold, relativeTo: .title3))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                Text(verbatim: subtitle)
                    .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                    .lines(1)
                Text(verbatim: detail)
                    .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                    .foregroundStyle(BP.inkSubtle)
                    .lines(1)
            }
            .padding(14)
            .frame(width: 164, height: 128, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(tint.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).stroke(tint.opacity(0.32), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(subtitle), \(detail)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// The Voyage banner: the voyage under way (or the invitation to start one) and the streak.
private struct PhoneVoyageBanner: View {
    let snapshot: VoyageModel.Snapshot?
    let action: () -> Void

    private var active: VoyageModel.Active? { snapshot?.active }

    private var accent: Color {
        guard let active else { return BP.accent }
        return PhoneTint.color(active.accent)
    }

    private var title: String {
        guard let active else { return T("Harbor Voyages") }
        return active.themeLabel
    }

    private var line: String {
        guard let active else { return T("Pick a direction and Harbor charts the next films, one at a time.") }
        if active.sailing { return T("Film %lld of %lld", min(active.watched + 1, max(active.slots.count, 1)), active.slots.count) }
        return T("Pick film %lld of %lld", active.picked + 1, active.targetLength)
    }

    private var button: String {
        guard let active else { return T("Plan a voyage") }
        return active.sailing ? T("Keep sailing") : T("Keep charting")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(accent.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(PhoneTheme.display(20, .semibold, relativeTo: .title3))
                        .foregroundStyle(BP.ink)
                        .lines(1)
                    Text(verbatim: line)
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(BP.inkMuted)
                        .lines(2)
                        .multilineTextAlignment(.leading)
                    if let streak = snapshot?.streak, streak > 1 {
                        Label(T("%lld day streak", streak), systemImage: "flame.fill")
                            .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(accent)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BP.inkSubtle)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous).fill(accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous).stroke(accent.opacity(0.30), lineWidth: 1))
            .padding(.horizontal, PhoneTheme.margin)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(line), \(button)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("discover-voyage")
    }
}

/// One genre on its own palette, with up to three of its backdrops once they have arrived.
private struct PhoneGenreTile: View {
    let genre: DiscoverModel.Build.Genre
    let art: [Meta]
    let action: () -> Void

    var body: some View {
        let from: Color = PhoneTint.color(genre.from)
        let to: Color = PhoneTint.color(genre.to)
        let ink: Color = Color(oklch: genre.ink) ?? Color(css: genre.ink) ?? BP.ink
        let pictures: [String] = art.prefix(3).compactMap { $0.background ?? $0.poster }
        return Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: -22) {
                    Spacer(minLength: 0)
                    ForEach(Array(pictures.enumerated()), id: \.offset) { _, url in
                        PhoneImage(url: url)
                            .frame(width: 54, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .opacity(0.9)
                    }
                }
                .padding(.trailing, 10)
                .padding(.bottom, 26)
                .accessibilityHidden(true)
                Text(verbatim: T(genre.genre))
                    .font(PhoneTheme.display(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(ink)
                    .lines(1)
                    .padding(12)
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: T(genre.genre)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("genre-\(genre.genre)")
    }
}

/// The lead tile of the genre grid: a shelf picked for the viewer.
private struct PhoneSurpriseTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "dice.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(verbatim: T("Surprise me"))
                    .font(PhoneTheme.display(17, .semibold, relativeTo: .headline))
            }
            .foregroundStyle(BP.on)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.accent))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: T("Surprise me")))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("genre-surprise")
    }
}

/// What Discover draws under `--fixtures`: a few genres and award bodies, so the bands are testable offline.
enum PhoneDiscoverFixtures {
    static let genres: [DiscoverModel.Build.Genre] = [
        DiscoverModel.Build.Genre(genre: "Action", from: "#b91c1c", to: "#7c2d12", ink: "#ffffff"),
        DiscoverModel.Build.Genre(genre: "Comedy", from: "#f59e0b", to: "#b45309", ink: "#1c1917"),
        DiscoverModel.Build.Genre(genre: "Drama", from: "#4338ca", to: "#1e1b4b", ink: "#ffffff"),
        DiscoverModel.Build.Genre(genre: "Thriller", from: "#0f766e", to: "#134e4a", ink: "#ffffff"),
    ]

    static let awards: [DiscoverModel.Awards.Summary] = [
        DiscoverModel.Awards.Summary(type: "oscars", title: "Academy Awards", shorthand: "Oscars", tint: "#f5c451", wins: 560, span: "1929–2024"),
        DiscoverModel.Awards.Summary(type: "emmys", title: "Emmy Awards", shorthand: "Emmys", tint: "#60a5fa", wins: 310, span: "1949–2024"),
    ]

    static let animeAwards: [DiscoverModel.AnimeAwardTile] = [
        DiscoverModel.AnimeAwardTile(id: "fixture-anime", name: "Harbor Anime Awards", shortName: "Anime", wins: 40),
    ]
}
