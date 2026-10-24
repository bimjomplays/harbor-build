import SwiftUI

/// Stats (views/wrapped.tsx + wrapped/cards.tsx) as a vertical story:
/// one card a page, swiped up and down, the cards and copy the TV's WrappedView draws in its order
/// (each left out when upstream's card would render nothing). A top title opens its page once the
/// story is down. Under `--fixtures` the stats are PhoneLibraryFixtures.stats.
struct PhoneWrappedStory: View {
    let offline: Bool
    let close: () -> Void
    let open: (Meta) -> Void
    @StateObject private var model = WrappedModel()
    @State private var current: Card?
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Card: String, CaseIterable, Identifiable {
        case hero, highlights, split, titles, actors, genres, heatmap
        var id: String { rawValue }
    }

    private var stats: WrappedModel.Stats? { offline ? PhoneLibraryFixtures.stats : model.stats }
    private var loading: Bool { offline ? false : model.loading }

    /// The cards wrapped.tsx renders for these stats, in its order.
    private var cards: [Card] {
        guard let s = stats, s.source != "empty" else { return [] }
        return Card.allCases.filter { c in
            switch c {
            case .hero, .split: return true
            case .highlights: return !s.archetype.label.isEmpty || s.longestBinge.count > 1 || s.firstPlay != nil
            case .titles: return !s.topTitles.isEmpty
            case .actors: return !s.topActors.isEmpty
            case .genres: return !s.topGenres.isEmpty
            case .heatmap: return !s.heatWeeks.isEmpty
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            PhoneBackground()
            deck
            header
        }
        .task { if !offline { await model.load() } }
        .presentedCover("wrapped")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wrapped-story")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: T("Stats"))
                    .font(PhoneTheme.display(28, .semibold, relativeTo: .title))
                    .foregroundStyle(BP.ink)
                if let year = stats?.year {
                    Text(verbatim: String(year))
                        .font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote))
                        .foregroundStyle(BP.inkSubtle)
                }
            }
            Spacer(minLength: 0)
            Button {
                PhoneFeedback.shared.tap()
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(verbatim: T("Close")))
            .accessibilityIdentifier("wrapped-close")
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 8)
    }

    @ViewBuilder private var deck: some View {
        if loading {
            VStack(spacing: 16) {
                SkeletonBlock(height: 420, radius: PhoneTheme.radiusLarge)
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.top, 90)
            .accessibilityIdentifier("wrapped-loading")
        } else if let s = stats, s.source != "empty" {
            let shown = cards
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { c in
                        // At accessibility sizes a card is as tall as its copy and the story scrolls like a
                        // page, so nothing is cut off at the card's edge.
                        if typeSize.isAccessibilitySize {
                            page(c, s)
                                .containerRelativeFrame(.horizontal)
                                .frame(minHeight: 420)
                                .id(c)
                        } else {
                            page(c, s)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(c)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(StoryPaging(paged: !typeSize.isAccessibilitySize))
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .trailing) { pips(shown) }
        } else {
            empty
                .padding(.horizontal, PhoneTheme.margin)
                .padding(.top, 100)
        }
    }

    /// The story's place: one dot a card down the right edge, the current one long and lit.
    private func pips(_ shown: [Card]) -> some View {
        let at: Int = current.flatMap { shown.firstIndex(of: $0) } ?? 0
        return VStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element) { i, _ in
                Capsule()
                    .fill(i == at ? BP.accent : BP.ink.opacity(0.25))
                    .frame(width: 4, height: i == at ? 18 : 6)
            }
        }
        .motion(.easeOut(duration: 0.2), value: at)
        .padding(.trailing, 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: T("Card %lld of %lld", at + 1, shown.count)))
        .accessibilityIdentifier("wrapped-pips")
    }

    /// One page: the card under the header, filling the rest of the screen.
    private func page(_ c: Card, _ s: WrappedModel.Stats) -> some View {
        shell(tint: c == .hero || c == .highlights) {
            switch c {
            case .hero: hero(s)
            case .highlights: highlights(s)
            case .split: split(s)
            case .titles: titles(s)
            case .actors: actors(s)
            case .genres: genres(s)
            case .heatmap: heatmap(s)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 84)
        .padding(.bottom, 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wrapped-card-\(c.rawValue)")
    }

    /// cards.tsx Card: a rounded panel, the tinted variant for Hero and Highlights.
    private func shell<C: View>(tint: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous)
                    .fill(tint
                          ? AnyShapeStyle(LinearGradient(colors: [BP.accent.opacity(0.18), BP.elevated.opacity(0.5), BP.elevated.opacity(0.3)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(BP.elevated.opacity(0.45)))
            )
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: T(text).uppercased())
            .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
            .tracking(2)
            .foregroundStyle(BP.inkSubtle)
            .padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
    }

    // HeroCard
    private func hero(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            stat(s.estimatedHours.formatted(), "hours watched", big: true)
            HStack(alignment: .lastTextBaseline, spacing: 32) {
                stat(s.totalTitles.formatted(), "titles")
                stat(s.totalPlays.formatted(), "plays")
            }
            Spacer(minLength: 0)
            if s.source == "local" {
                Text(verbatim: T("Estimated from your local history. Connect Trakt or Simkl for the full picture."))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ value: String, _ unit: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value)
                .font(PhoneTheme.display(big ? 72 : 44, .medium, relativeTo: .largeTitle))
                .foregroundStyle(BP.ink)
                .lines(1)
                .minimumScaleFactor(0.5)
            Text(verbatim: T(unit))
                .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                .foregroundStyle(BP.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    // HighlightsCard
    private func highlights(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            label("Highlights")
            if !s.archetype.label.isEmpty { highlight("sparkles", s.archetype.label, s.archetype.blurb) }
            if s.longestBinge.count > 1 {
                let date = s.bingeDate ?? s.longestBinge.date
                highlight("flame", T("Longest binge"), T("%lld in a day", s.longestBinge.count) + " · " + date)
            }
            if let first = s.firstPlay { highlight("calendar.badge.clock", T("Where it started"), first.title) }
            Spacer(minLength: 0)
        }
    }

    private func highlight(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BP.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.canvas.opacity(0.6)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(BP.ink)
                Text(verbatim: body)
                    .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                    .foregroundStyle(BP.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // SplitCard
    private struct SplitRow: Identifiable {
        var icon: String
        var label: String
        var n: Int
        var color: Color
        var id: String { label }
    }

    private func split(_ s: WrappedModel.Stats) -> some View {
        let total = max(1, s.split.movies + s.split.series + s.split.anime)
        let rows = [
            SplitRow(icon: "film", label: "Movies", n: s.split.movies, color: Color(hex: 0x38bdf8)),
            SplitRow(icon: "tv", label: "Series", n: s.split.series, color: Color(hex: 0xa78bfa)),
            SplitRow(icon: "sparkles", label: "Anime", n: s.split.anime, color: Color(hex: 0x34d399)),
        ]
        return VStack(alignment: .leading, spacing: 20) {
            label("What you watched")
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: r.icon).foregroundStyle(BP.inkMuted).frame(width: 22).accessibilityHidden(true)
                        Text(verbatim: T(r.label))
                            .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                            .foregroundStyle(BP.inkMuted)
                        Spacer(minLength: 0)
                        Text(verbatim: "\(r.n)")
                            .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(BP.ink)
                            .monospacedDigit()
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BP.canvas.opacity(0.7))
                            Capsule().fill(r.color).frame(width: g.size.width * CGFloat(r.n) / CGFloat(total))
                        }
                    }
                    .frame(height: 10)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }

    // TopTitlesCard: each row opens its title.
    private func titles(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Top titles")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(s.topTitles.prefix(10).enumerated()), id: \.element.id) { i, tt in
                    Button {
                        PhoneFeedback.shared.tap()
                        open(Meta(id: tt.id, type: tt.type, name: tt.title, poster: s.posters[tt.id]))
                    } label: {
                        HStack(spacing: 12) {
                            Text(verbatim: "\(i + 1)")
                                .font(PhoneTheme.display(17, .medium, relativeTo: .body))
                                .foregroundStyle(BP.inkSubtle)
                                .frame(width: 22, alignment: .trailing)
                            PhoneImage(url: s.posters[tt.id])
                                .frame(width: 30, height: 45)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            Text(verbatim: tt.title)
                                .font(PhoneTheme.sans(16, .medium, relativeTo: .body))
                                .foregroundStyle(BP.ink)
                                .lines(1)
                            Spacer(minLength: 0)
                            Text(verbatim: "\(tt.count)")
                                .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(BP.inkMuted)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.98))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(i + 1). \(tt.title)"))
                    .accessibilityValue(Text(verbatim: TCount(tt.count, one: "%lld play", "%lld plays")))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("wrapped-title-\(tt.id)")
                }
            }
            Spacer(minLength: 0)
        }
    }

    // ActorsCard
    private func actors(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label("People you watch")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(s.topActors, id: \.name) { a in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(BP.canvas.opacity(0.7))
                            if let photo = a.photo {
                                PhoneImage(url: photo).clipShape(Circle())
                            } else {
                                Text(verbatim: initials(a.name))
                                    .font(PhoneTheme.display(15, .medium, relativeTo: .body))
                                    .foregroundStyle(BP.inkSubtle)
                            }
                        }
                        .frame(width: 46, height: 46)
                        .overlay(Circle().stroke(BP.edge, lineWidth: 1))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: a.name)
                                .font(PhoneTheme.sans(16, .medium, relativeTo: .body))
                                .foregroundStyle(BP.ink)
                                .lines(1)
                            Text(verbatim: T("%lld titles", a.count))
                                .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                                .foregroundStyle(BP.inkMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// cards.tsx initials().
    private func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        let out = (first + last).uppercased()
        return out.isEmpty ? "?" : out
    }

    // GenresCard
    private func genres(_ s: WrappedModel.Stats) -> some View {
        let maxCount = max(1, s.topGenres.first?.count ?? 1)
        return VStack(alignment: .leading, spacing: 16) {
            label("Top genres")
            ForEach(s.topGenres, id: \.genre) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: g.genre)
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                        .foregroundStyle(BP.ink)
                        .lines(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BP.canvas.opacity(0.7))
                            Capsule().fill(BP.accent.opacity(0.8)).frame(width: geo.size.width * CGFloat(g.count) / CGFloat(maxCount))
                        }
                    }
                    .frame(height: 8)
                    .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // HeatmapCard: cards.tsx heatColor as the engine's level (0 empty … 4 full accent). The year runs
    // down the card (a week a row, Monday to Sunday across), so 53 weeks fit a phone's width.
    private func heatmap(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Your watch year")
            GeometryReader { geo in
                let rows = max(1, s.heatWeeks.count)
                let cell = max(2, min((geo.size.height - CGFloat(rows - 1) * 2) / CGFloat(rows), (geo.size.width - 12) / 7))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(s.heatWeeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 2) {
                            ForEach(week, id: \.key) { d in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(heat(d.level))
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityHidden(true)
        }
    }

    private func heat(_ level: Int) -> Color {
        switch level {
        case 4: return BP.accent
        case 3: return BP.accent.opacity(0.7)
        case 2: return BP.accent.opacity(0.45)
        case 1: return BP.accent.opacity(0.25)
        default: return BP.canvas.opacity(0.5)
        }
    }

    // WrappedEmpty
    private var empty: some View {
        EmptyState(title: T("Nothing to show yet"),
                   message: T("Connect Trakt or Simkl, or start watching, and your stats will build themselves."),
                   systemImage: "chart.bar")
            .accessibilityIdentifier("wrapped-empty")
    }
}

/// The story's one-card-a-page snap, off at accessibility text sizes where a card can outgrow the screen.
private struct StoryPaging: ViewModifier {
    let paged: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if paged { content.scrollTargetBehavior(.paging) } else { content }
    }
}
