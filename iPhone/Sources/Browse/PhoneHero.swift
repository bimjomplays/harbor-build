import SwiftUI

/// The Home hero ("Spotlight"): the lead titles as full-width pages whose art runs to the very top of the
/// screen, under the status bar. Each page has a kicker (only when the title really ranks somewhere), its
/// logo (or its name), a facts line, a Play pill with a Watchlist and a Details circle, and dots under it
/// all. Tapping the art opens the title. It cycles by itself, as the TV's hero does, and stops while a
/// finger is on it.
///
/// The hero is `height` tall counting from the screen's top edge: Home shifts it up by the top safe area
/// (PhoneHomeView), so the art starts at y = 0 and everything below is laid out as if it began there. The art is
/// a band across the top `artHeight` tall, close to a backdrop's own 16:9 shape; the text block runs from over the
/// art's lower part down onto the canvas under it.
struct PhoneHero: View {
    /// The art band's height for a screen `width` points wide (its short side). A backdrop is 16:9, so at the
    /// screen's width it is 0.5625x as tall as wide; the band is 0.68x, a little taller so it also covers the
    /// status bar, and aspect-filling the backdrop into it crops only its sides: 83% of the picture's width
    /// shows (440 x 299 pt on a 6.9" iPhone). The old hero drew the art over the whole 535 pt hero, which showed
    /// 46%: a narrow, zoomed middle slice.
    static func artHeight(forWidth width: CGFloat) -> CGFloat { (max(320, width) * 0.68).rounded() }

    /// The hero's height: the art band and the text block's part below it (the facts, the buttons, the dots).
    /// The kicker and the logo sit over the art's lower part.
    static func height(forWidth width: CGFloat) -> CGFloat { artHeight(forWidth: width) + belowArt }

    /// How far the hero runs past the bottom of its art.
    static let belowArt: CGFloat = 152

    /// The share of a picture's width (aspect = width / height) the art band shows on a screen `width` wide.
    static func visibleShare(aspect: CGFloat, width: CGFloat) -> CGFloat {
        min(1, width / (artHeight(forWidth: width) * aspect))
    }

    let items: [Meta]
    /// "#1 in Top 10 Today" and the like, by title id: only titles that really rank get one.
    var kickers: [String: String] = [:]
    /// The hero's height from the top edge of the screen.
    let height: CGFloat
    /// The art band's height from the top edge of the screen.
    let artHeight: CGFloat
    /// How far the feed is pulled down past its top (pull to refresh, rubber banding): the art grows to
    /// fill it, so no gap opens above the hero.
    var stretch: CGFloat = 0
    /// Opens the title page.
    let open: (Meta) -> Void
    /// Play: the title page, which opens the picker (and the player) as soon as it knows what to play.
    let play: (Meta) -> Void

    @State private var current: String?
    @State private var dragging = false
    /// On screen in Home's feed (a fifth of it at least): a hero scrolled away stops turning pages nobody sees.
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var currentId: String { current ?? items.first?.id ?? "" }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { meta in
                        PhoneHeroPage(meta: meta, kicker: kickers[meta.id], height: height, artHeight: artHeight, stretch: stretch,
                                      open: open, play: play)
                            .containerRelativeFrame(.horizontal)
                            .id(meta.id)
                    }
                }
                .scrollTargetLayout()
            }
            // The art grows upward when the feed is pulled down; the pager must not cut that off.
            .scrollClipDisabled()
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            // The pager's own scroll phase, not a DragGesture: a drag gesture on the pager competed with
            // the feed's vertical scroll, and a drag up from the art could end as a tap that opened the title.
            // A finger on the pager (tracking, moving) or a page still settling holds the cycle.
            .onScrollPhaseChange { _, phase in
                dragging = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items) { meta in
                        Capsule()
                            .fill(meta.id == currentId ? BP.accent : BP.ink.opacity(0.32))
                            .frame(width: meta.id == currentId ? 22 : 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PhoneHeroPage.margin)
                .padding(.bottom, 22)
                .motion(.easeOut(duration: 0.2), value: currentId)
                .accessibilityHidden(true)
            }
        }
        .frame(height: height)
        .onScrollVisibilityChange(threshold: 0.2) { visible = $0 }
        .task(id: CycleKey(ids: items.map(\.id), still: reduceMotion || voiceOver)) { await cycle() }
        .accessibilityElement(children: .contain)
        // The dots are hidden and a lazy page off screen is not in the tree, so the carousel says where it
        // is and VoiceOver can turn the page from its actions rotor.
        .accessibilityLabel(Text(items.count > 1 ? T("Featured, %lld of %lld", position + 1, items.count) : T("Featured")))
        .accessibilityAction(named: Text(T("Next title"))) { turn(by: 1) }
        .accessibilityAction(named: Text(T("Previous title"))) { turn(by: -1) }
        .accessibilityIdentifier("hero-carousel")
    }

    private struct CycleKey: Equatable {
        let ids: [String]
        let still: Bool
    }

    private var position: Int { items.firstIndex(where: { $0.id == currentId }) ?? 0 }

    /// One page forward or back, wrapping; no travel under Reduce Motion.
    private func turn(by step: Int) {
        guard items.count > 1 else { return }
        let target = items[(position + step + items.count) % items.count].id
        withMotion(.easeInOut(duration: 0.5)) { current = target }
    }

    /// Moves to the next title every few seconds. Not under fixtures (screenshots must hold still), with
    /// Reduce Motion on, VoiceOver running (a page that turns under the reader's cursor), or with a
    /// single title.
    private func cycle() async {
        guard items.count > 1, !Fixtures.active, !PhoneMotion.reduced, !reduceMotion, !voiceOver else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, !dragging, visible else { continue }
            guard let index = items.firstIndex(where: { $0.id == currentId }) else { continue }
            let next = items[(index + 1) % items.count].id
            withMotion(.easeInOut(duration: 0.5)) { current = next }
        }
    }
}

private struct PhoneHeroPage: View {
    /// The page's side margin: the mockup's 20, a little wider than the rails below.
    static let margin: CGFloat = 20

    let meta: Meta
    let kicker: String?
    let height: CGFloat
    let artHeight: CGFloat
    let stretch: CGFloat
    let open: (Meta) -> Void
    let play: (Meta) -> Void

    @ObservedObject private var marks = CardMarksStore.shared
    @ObservedObject private var actions = PhoneTitleActions.shared
    /// A logo the engine found for a title that came without one (lib/logo resolveLogo).
    @State private var resolvedLogo: String?

    private var saved: Bool { actions.isSaved(meta, marks: marks.byId[meta.id]) }
    private var logoURL: String? { meta.logo ?? resolvedLogo }
    /// The backdrop (TMDB's at w1280, sharp at the screen's width); the poster only when there is none.
    private var artURL: String? { PhoneArt.backdrop(meta.background) ?? meta.poster }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button { open(meta) } label: { art }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: meta.name))
                .accessibilityHint(Text(T("Opens the title")))
                .accessibilityIdentifier("hero-open-\(meta.id)")
            VStack(alignment: .leading, spacing: 0) {
                if let kicker, !kicker.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 12, weight: .bold))
                        Text(verbatim: kicker.uppercased())
                            .font(PhoneTheme.sans(12.5, .semibold, relativeTo: .caption))
                            .tracking(2.2)
                            .lines(1)
                    }
                    .foregroundStyle(BP.accent)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .padding(.bottom, 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("hero-kicker-\(meta.id)")
                }
                title
                PhoneHeroFacts(meta: meta)
                    .padding(.top, 16)
                actionRow
                    .padding(.top, 22)
            }
            .padding(.horizontal, Self.margin)
            // Room for the dots PhoneHero draws under everything.
            .padding(.bottom, 52)
        }
        .frame(height: height)
        .task(id: meta.id) {
            await resolveLogo()
            await PhoneTitleActions.shared.loadSaved(meta)
        }
    }

    /// The art band with its scrims, edge to edge across the top of the page, then the canvas: the whole page
    /// opens the title. Pulled past the top, the band grows from its bottom edge so its top stays glued to the
    /// screen's.
    private var art: some View {
        VStack(spacing: 0) {
            band
            Color.clear
        }
        .frame(height: height)
        .contentShape(Rectangle())
    }

    private var band: some View {
        ZStack {
            // No backdrop (or none yet): an accent wash instead of a dark hole.
            LinearGradient(colors: [BP.accent.opacity(0.38), BP.surface], startPoint: .top, endPoint: .bottom)
            PhoneImage(url: artURL, plate: false)
            // Status bar legibility: a soft scrim from the very top, fading out, not a bar.
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .black.opacity(0.22), location: 0.55),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 190)
                .frame(maxHeight: .infinity, alignment: .top)
            // The left side darkens under the text.
            LinearGradient(colors: [BP.canvas.opacity(0.55), BP.canvas.opacity(0)], startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5))
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
                .frame(height: artHeight * 0.55)
                .frame(maxHeight: .infinity, alignment: .bottom)
            // Into the canvas at the bottom, under the kicker and the logo.
            LinearGradient(stops: [.init(color: BP.canvas.opacity(0), location: 0.45),
                                   .init(color: BP.canvas.opacity(0.42), location: 0.62),
                                   .init(color: BP.canvas.opacity(0.85), location: 0.8),
                                   .init(color: BP.canvas, location: 0.98)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: artHeight)
        .clipped()
        .scaleEffect(1 + stretch / max(1, artHeight), anchor: .bottom)
    }

    @ViewBuilder private var title: some View {
        if let logoURL {
            PhoneImage(url: logoURL, contentMode: .fit, alignment: .leading, plate: false)
                .frame(width: 268, height: 80, alignment: .leading)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: meta.name))
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(verbatim: meta.name)
                .font(PhoneTheme.display(34, .semibold, relativeTo: .largeTitle))
                .foregroundStyle(BP.ink)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                .lines(2)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Play as a wide pill, then Watchlist and Details as glass circles.
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                PhoneFeedback.shared.tap()
                play(meta)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "play.fill").font(.system(size: 17, weight: .semibold))
                    Text(T("Play")).font(PhoneTheme.sans(18, .semibold, relativeTo: .body))
                }
                .foregroundStyle(BP.canvas)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Capsule().fill(BP.ink))
                .shadow(color: .black.opacity(0.3), radius: 11, y: 4)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hero-play-\(meta.id)")
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        PhoneFeedback.shared.tap()
                        let current = saved
                        let title = meta
                        Task { await PhoneTitleActions.shared.toggleSaved(title, current: current) }
                    } label: {
                        Image(systemName: saved ? "checkmark" : "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(BP.ink)
                            .frame(width: 54, height: 54)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(saved ? T("Saved") : T("Watchlist")))
                    .accessibilityIdentifier("hero-watchlist-\(meta.id)")
                    Button {
                        PhoneFeedback.shared.tap()
                        open(meta)
                    } label: {
                        Image(systemName: "info")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(BP.ink)
                            .frame(width: 54, height: 54)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(T("Details")))
                    .accessibilityIdentifier("hero-details-\(meta.id)")
                }
            }
        }
    }

    private func resolveLogo() async {
        guard meta.logo == nil, !Fixtures.active, ["movie", "series", "anime"].contains(meta.type) else { return }
        let p = ProfilesStore.shared.active
        let answer: String?? = try? await HarborEngine.shared.call("titleLogo.resolve", [meta, p?.id ?? "default", p?.linked ?? true])
        guard !Task.isCancelled, let found = answer, let url = found, !url.isEmpty else { return }
        resolvedLogo = url
    }
}

/// "2022  IMDb 8.3  Animation · Sci-Fi": only the parts the title has; nothing at all when it has none.
private struct PhoneHeroFacts: View {
    let meta: Meta

    private var year: String? { Self.text(meta.releaseInfo) }
    private var rating: String? { Self.text(meta.imdbRating) }
    private var runtime: String? { meta.type == "movie" ? Self.text(meta.runtime) : nil }
    private var genres: String? {
        let names: [String] = (meta.genres ?? []).filter { !$0.isEmpty }.prefix(2).map { $0 }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        if year != nil || rating != nil || runtime != nil || genres != nil {
            HStack(spacing: 8) {
                if let year { Text(verbatim: year) }
                if let rating {
                    HStack(spacing: 6) {
                        Text(verbatim: "IMDb")
                            .font(PhoneTheme.sans(10.5, .bold, relativeTo: .caption2))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: 0xf5c518)))
                        Text(verbatim: rating)
                            .fontWeight(.semibold)
                            .foregroundStyle(BP.ink)
                    }
                }
                if let runtime { Text(verbatim: runtime) }
                if let genres {
                    Text(verbatim: genres)
                        .lines(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .font(PhoneTheme.sans(14.5, .medium, relativeTo: .subheadline))
            .foregroundStyle(Color(hex: 0xc9cbcd))
            .shadow(color: .black.opacity(0.5), radius: 6)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: meta.facts))
        }
    }
}
