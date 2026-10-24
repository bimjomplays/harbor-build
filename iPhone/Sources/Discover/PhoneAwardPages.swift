import SwiftUI

/// One award body's page (the TV's AwardDetailView): its winners by category, narrowed by decade and
/// category, paged in 90 at a time as the end of the list nears. A winner opens its title: an IMDb id
/// at once, else a TMDB lookup (which needs a key).
struct PhoneAwardPage: View {
    let summary: DiscoverModel.Awards.Summary
    let open: (Meta) -> Void

    struct Page: Decodable {
        struct Chip: Decodable, Identifiable { var key: String; var name: String; var count: Int; var id: String { key } }
        struct Winner: Decodable { var year: Int; var workTitle: String; var recipients: [String]; var imdb: String?; var poster: String? }
        struct Group: Decodable, Identifiable { var key: String; var name: String; var preferTv: Bool; var entries: [Winner]; var id: String { key } }
        var title: String; var shorthand: String; var tint: String
        var wins: Int; var span: String; var categoryCount: Int
        var decades: [Int]; var categories: [Chip]; var groups: [Group]
        var mounted: Int; var more: Bool
    }
    struct Outcome: Decodable { var status: String; var meta: Meta? }

    private static let pageSize = 90

    @State private var page: Page?
    @State private var failed = false
    @State private var decade: Int?
    @State private var category = "all"
    @State private var limit = PhoneAwardPage.pageSize
    @State private var busy: String?
    @State private var missing: Set<String> = []

    private var hasKey: Bool { !SettingsBridge.shared.slice.tmdbKey.isEmpty }
    private var tint: Color { PhoneTint.color(summary.tint) }
    private var filterKey: String { (decade.map { String($0) } ?? "all") + "|" + category }
    private var readKey: String { filterKey + "|" + String(limit) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                chips
                list
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(summary.shorthand)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: readKey) { await read() }
        .onChange(of: decade) { _, _ in resetPaging() }
        .onChange(of: category) { _, _ in resetPaging() }
        .accessibilityIdentifier("award-page")
    }

    /// Under `--fixtures` the engine holds no catalog: a small page stands in so the screen is testable.
    private var offline: Bool { Fixtures.active && !Fixtures.liveRooms }

    private static func fixturePage(_ summary: DiscoverModel.Awards.Summary) -> Page {
        let entries: [Page.Winner] = [
            Page.Winner(year: 2023, workTitle: "Past Lives", recipients: ["Celine Song"], imdb: "tt900000", poster: nil),
            Page.Winner(year: 2022, workTitle: "Anatomy of a Fall", recipients: ["Justine Triet"], imdb: "tt900002", poster: nil),
        ]
        let groups: [Page.Group] = [Page.Group(key: "best-picture", name: "Best Picture", preferTv: false, entries: entries)]
        let cats: [Page.Chip] = [Page.Chip(key: "best-picture", name: "Best Picture", count: entries.count)]
        return Page(title: summary.title, shorthand: summary.shorthand, tint: summary.tint, wins: entries.count,
                    span: "2022–2023", categoryCount: 1, decades: [2020], categories: cats, groups: groups,
                    mounted: entries.count, more: false)
    }

    private func read() async {
        let want = readKey
        if offline {
            page = Self.fixturePage(summary)
            return
        }
        // The 4 MB catalog is handed to the engine once, the first time any award page asks.
        await AwardsCatalog.installIfNeeded()
        let dec: AnyJSON = decade.map { AnyJSON.number(Double($0)) } ?? AnyJSON.null
        let got: Page? = try? await HarborEngine.shared.call("discoverRoom.awardPage", [summary.type, dec, category, limit])
        // Engine calls do not stop on cancel: a chip pressed while the last read ran must not get its answer.
        guard !Task.isCancelled, want == readKey else { return }
        if let got {
            page = got
            failed = false
        } else if page == nil {
            failed = true
        }
    }

    private func resetPaging() {
        limit = Self.pageSize
        missing = []
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 58, height: 58)
                .background(Circle().fill(tint.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: T(page?.title ?? summary.title))
                    .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("award-title")
                if let page {
                    Text(verbatim: counts(page))
                        .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                        .foregroundStyle(BP.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    private func counts(_ p: Page) -> String {
        var parts: [String] = [TCount(p.wins, one: "%lld winner", "%lld winners")]
        if !p.span.isEmpty { parts.append(p.span) }
        parts.append(TCount(p.categoryCount, one: "%lld category", "%lld categories"))
        return parts.joined(separator: " • ")
    }

    @ViewBuilder private var chips: some View {
        if let page {
            if !page.decades.isEmpty {
                ChipRow {
                    GlassChip(title: T("All years"), selected: decade == nil) { decade = nil }
                    ForEach(page.decades, id: \.self) { d in
                        GlassChip(title: String(d) + "s", selected: decade == d) { decade = decade == d ? nil : d }
                    }
                }
            }
            if !page.categories.isEmpty {
                ChipRow {
                    GlassChip(title: T("All categories"), selected: category == "all") { category = "all" }
                    ForEach(page.categories) { c in
                        GlassChip(title: c.name + " · " + String(c.count), selected: category == c.key) { category = c.key }
                    }
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        if let page {
            if page.groups.isEmpty {
                Text(verbatim: T("No winners match these filters."))
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                    .foregroundStyle(BP.inkSubtle)
                    .padding(.horizontal, PhoneTheme.margin)
            } else {
                ForEach(page.groups) { group in section(group) }
                if page.more {
                    // The sentinel: reaching the end of what is mounted pages the next 90 in.
                    ProgressView().tint(BP.inkMuted)
                        .frame(maxWidth: .infinity)
                        .onAppear { if limit <= page.mounted { limit = page.mounted + Self.pageSize } }
                }
            }
        } else if failed {
            ErrorPlate(title: T("Couldn't load this award right now.")) {
                failed = false
                Task { await read() }
            }
        } else {
            ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity).padding(.top, 30)
        }
    }

    private func section(_ group: Page.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: group.name)
                    .font(PhoneTheme.sans(17, .bold, relativeTo: .headline))
                    .foregroundStyle(BP.ink)
                Spacer(minLength: 8)
                Text(verbatim: TCount(group.entries.count, one: "%lld winner", "%lld winners"))
                    .font(PhoneTheme.sans(12, .medium, relativeTo: .caption))
                    .foregroundStyle(BP.inkSubtle)
            }
            ForEach(Array(group.entries.enumerated()), id: \.offset) { i, entry in
                winner(entry, key: group.key + "#" + String(i), preferTv: group.preferTv)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 6)
    }

    private func secondLine(_ e: Page.Winner, key: String) -> String? {
        if busy == key { return T("Checking with TMDB…") }
        if missing.contains(key) { return T("No match found") }
        if e.imdb == nil && !hasKey { return T("Needs a TMDB key") }
        let names: String = e.recipients.prefix(2).joined(separator: ", ")
        return names.isEmpty ? nil : names
    }

    private func winner(_ e: Page.Winner, key: String, preferTv: Bool) -> some View {
        let unlinked: Bool = e.imdb == nil && !hasKey
        let second: String? = secondLine(e, key: key)
        return Button { activate(e, key: key, preferTv: preferTv) } label: {
            HStack(spacing: 12) {
                if let poster = e.poster {
                    PhoneImage(url: poster)
                        .frame(width: 40, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: String(e.year))
                            .font(PhoneTheme.sans(14, .bold, relativeTo: .subheadline))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                        Text(verbatim: e.workTitle)
                            .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                            .foregroundStyle(BP.ink)
                            .lines(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let second {
                        Text(verbatim: second)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                            .lines(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.ink.opacity(0.06)))
            .opacity(unlinked ? 0.55 : 1)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityLabel(Text(verbatim: e.workTitle + ", " + String(e.year)))
        .accessibilityIdentifier("award-winner-\(key)")
    }

    /// A winner opens its title: an IMDb id at once, else a TMDB lookup scored by the engine.
    private func activate(_ e: Page.Winner, key: String, preferTv: Bool) {
        guard busy == nil else { return }
        if e.imdb == nil && !hasKey {
            PhoneToaster.shared.show(T("Add a TMDB key in Settings to open this one."))
            return
        }
        if offline, let imdb = e.imdb {
            open(Meta(id: imdb, type: preferTv ? "series" : "movie", name: e.workTitle))
            return
        }
        busy = key
        missing.remove(key)
        let from: String = filterKey
        let p = ProfilesStore.shared.active
        let profileId: String = p?.id ?? "default"
        let linked: Bool = p?.linked ?? true
        let imdb: AnyJSON = e.imdb.map { AnyJSON.string($0) } ?? AnyJSON.null
        let title: String = e.workTitle
        let year: Int = e.year
        Task {
            let out: Outcome? = try? await HarborEngine.shared.call("discoverRoom.awardOpen", [title, year, imdb, preferTv, profileId, linked])
            busy = nil
            // A lookup answering after the filters changed must not open a title off screen.
            guard from == filterKey else { return }
            let status: String = out?.status ?? "missing"
            if status == "open", let meta = out?.meta {
                open(meta)
            } else if status == "nokey" {
                PhoneToaster.shared.show(T("Add a TMDB key in Settings to open this one."))
            } else {
                missing.insert(key)
            }
        }
    }
}

/// An anime award source's page (the TV's AnimeAwardView): a chip per bundled source, a year filter,
/// then each category with its winners. A winner opens its mapped anime id, else a TMDB search.
struct PhoneAnimeAwardPage: View {
    let sources: [DiscoverModel.AnimeAwardTile]
    let open: (Meta) -> Void

    struct Award: Decodable {
        struct Winner: Decodable { var year: Int; var title: String; var mapped: Bool }
        struct Category: Decodable, Identifiable { var key: String; var name: String; var isAOTY: Bool; var winners: [Winner]; var id: String { key } }
        struct YearCount: Decodable { var year: Int; var count: Int }
        var id: String; var name: String; var totalWins: Int; var yearSpan: String; var years: [Int]; var perYear: [YearCount]; var categories: [Category]
    }

    @State private var source: String
    @State private var year: Int?
    @State private var data: Award?
    @State private var failed = false
    @State private var busy: String?

    init(sources: [DiscoverModel.AnimeAwardTile], initial: String, open: @escaping (Meta) -> Void) {
        self.sources = sources
        self.open = open
        _source = State(initialValue: initial)
    }

    private var hasKey: Bool { !SettingsBridge.shared.slice.tmdbKey.isEmpty }

    /// The year filter keeps only that year's winners and drops the categories left empty.
    private var categories: [Award.Category] {
        guard let data else { return [] }
        guard let year else { return data.categories }
        var out: [Award.Category] = []
        for c in data.categories {
            let winners: [Award.Winner] = c.winners.filter { $0.year == year }
            if !winners.isEmpty { out.append(Award.Category(key: c.key, name: c.name, isAOTY: c.isAOTY, winners: winners)) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                if sources.count > 1 {
                    ChipRow {
                        ForEach(sources) { s in
                            GlassChip(title: s.name, selected: s.id == source) { source = s.id }
                        }
                    }
                }
                if let data, !data.years.isEmpty {
                    ChipRow {
                        GlassChip(title: T("All years"), selected: year == nil) { year = nil }
                        ForEach(data.years, id: \.self) { y in
                            GlassChip(title: String(y), selected: year == y) { year = year == y ? nil : y }
                        }
                    }
                }
                list
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(T("Anime award"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: source) {
            if data?.id == source { return }
            year = nil
            failed = false
            if Fixtures.active && !Fixtures.liveRooms {
                // Under --fixtures the engine holds no anime catalog: a small one stands in.
                let winners: [Award.Winner] = [Award.Winner(year: 2023, title: "Frieren: Beyond Journey's End", mapped: false)]
                let cats: [Award.Category] = [Award.Category(key: "aoty", name: "Anime of the Year", isAOTY: true, winners: winners)]
                data = Award(id: source, name: sources.first(where: { $0.id == source })?.name ?? "", totalWins: 1, yearSpan: "2023",
                             years: [2023], perYear: [Award.YearCount(year: 2023, count: 1)], categories: cats)
                return
            }
            let got: Award? = try? await HarborEngine.shared.call("discoverRoom.animeAward", [source])
            // Engine calls do not stop when the task is cancelled: a source chip pressed while the
            // previous one still loaded must not get that source's winners under its name.
            guard !Task.isCancelled else { return }
            data = got
            failed = got == nil
        }
        .accessibilityIdentifier("anime-award-page")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: data?.name ?? sources.first(where: { $0.id == source })?.name ?? "")
                .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                .foregroundStyle(BP.ink)
                .accessibilityAddTraits(.isHeader)
            if let data {
                Text(verbatim: summary(data))
                    .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    private func summary(_ d: Award) -> String {
        var parts: [String] = [T("%lld recorded winners", d.totalWins),
                               d.categories.count == 1 ? T("%lld category", 1) : T("%lld categories", d.categories.count)]
        if !d.yearSpan.isEmpty { parts.append(d.yearSpan) }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder private var list: some View {
        if data != nil {
            if categories.isEmpty {
                Text(verbatim: T("No winners match these filters."))
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                    .foregroundStyle(BP.inkSubtle)
                    .padding(.horizontal, PhoneTheme.margin)
            } else {
                ForEach(categories) { c in section(c) }
            }
        } else if failed {
            ErrorPlate(title: T("Couldn't load this award right now.")) {
                let again = source
                source = ""
                source = again
            }
        } else {
            ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity).padding(.top, 30)
        }
    }

    private func section(_ c: Award.Category) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: c.name)
                .font(PhoneTheme.sans(17, .bold, relativeTo: .headline))
                .foregroundStyle(c.isAOTY ? BP.accent : BP.ink)
            ForEach(Array(c.winners.enumerated()), id: \.offset) { i, w in
                winner(w, key: c.key + "#" + String(i))
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 6)
    }

    private func winner(_ w: Award.Winner, key: String) -> some View {
        let inert: Bool = !w.mapped && !hasKey
        return Button { activate(w, key: key) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: String(w.year))
                    .font(PhoneTheme.sans(14, .bold, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundStyle(BP.inkSubtle)
                Text(verbatim: w.title)
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if busy == key { ProgressView().tint(BP.inkMuted) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.ink.opacity(0.06)))
            .opacity(inert ? 0.55 : 1)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityLabel(Text(verbatim: w.title + ", " + String(w.year)))
        .accessibilityIdentifier("anime-award-winner-\(key)")
    }

    private func activate(_ w: Award.Winner, key: String) {
        guard busy == nil else { return }
        if !w.mapped && !hasKey {
            PhoneToaster.shared.show(T("Add a TMDB key in Settings to open this one."))
            return
        }
        busy = key
        let from: String = source
        let title: String = w.title
        let year: Int = w.year
        let p = ProfilesStore.shared.active
        let profileId: String = p?.id ?? "default"
        let linked: Bool = p?.linked ?? true
        Task {
            let meta: Meta? = try? await HarborEngine.shared.call("discoverRoom.animeAwardOpen", [title, year, profileId, linked])
            busy = nil
            // A search answering after the viewer moved to another source must not open a title from a list no longer on screen.
            guard source == from else { return }
            if let meta { open(meta) } else { PhoneToaster.shared.show(T("No match found")) }
        }
    }
}
