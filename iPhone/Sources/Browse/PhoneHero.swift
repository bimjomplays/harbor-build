import SwiftUI

/// The Home hero: the lead titles as full-width pages, each with its logo
/// (or its name), a facts line and Play + Watchlist glass buttons, and dots under the art. Tapping the
/// art opens the title. It cycles by itself, as the TV's hero does, and stops while a finger is on it.
struct PhoneHero: View {
    static let height: CGFloat = 500

    let items: [Meta]
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
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { meta in
                        PhoneHeroPage(meta: meta, open: open, play: play)
                            .containerRelativeFrame(.horizontal)
                            .id(meta.id)
                    }
                }
                .scrollTargetLayout()
            }
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
                            .fill(meta.id == currentId ? BP.ink : BP.ink.opacity(0.3))
                            .frame(width: meta.id == currentId ? 16 : 6, height: 6)
                    }
                }
                .padding(.bottom, 10)
                .motion(.easeOut(duration: 0.2), value: currentId)
                .accessibilityHidden(true)
            }
        }
        .frame(height: Self.height)
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
    let meta: Meta
    let open: (Meta) -> Void
    let play: (Meta) -> Void

    @ObservedObject private var marks = CardMarksStore.shared
    @ObservedObject private var actions = PhoneTitleActions.shared
    /// A logo the engine found for a title that came without one (lib/logo resolveLogo).
    @State private var resolvedLogo: String?

    private var saved: Bool { actions.isSaved(meta, marks: marks.byId[meta.id]) }
    private var logoURL: String? { meta.logo ?? resolvedLogo }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button { open(meta) } label: {
                ZStack {
                    PhoneImage(url: meta.background ?? meta.poster)
                    LinearGradient(colors: [.clear, BP.canvas.opacity(0.35), BP.canvas],
                                   startPoint: .center, endPoint: .bottom)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: meta.name))
            .accessibilityHint(Text(T("Opens the title")))
            .accessibilityIdentifier("hero-open-\(meta.id)")
            VStack(alignment: .leading, spacing: 10) {
                title
                if !meta.facts.isEmpty {
                    Text(verbatim: meta.facts)
                        .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(BP.inkMuted)
                        .lines(1)
                }
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            PhoneFeedback.shared.tap()
                            play(meta)
                        } label: {
                            Label(T("Play"), systemImage: "play.fill")
                                .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("hero-play-\(meta.id)")
                        Button {
                            PhoneFeedback.shared.tap()
                            let current = saved
                            let title = meta
                            Task { await PhoneTitleActions.shared.toggleSaved(title, current: current) }
                        } label: {
                            Label(saved ? T("Saved") : T("Watchlist"), systemImage: saved ? "checkmark" : "plus")
                                .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("hero-watchlist-\(meta.id)")
                    }
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.bottom, 34)
        }
        .frame(height: PhoneHero.height)
        .task(id: meta.id) {
            await resolveLogo()
            await PhoneTitleActions.shared.loadSaved(meta)
        }
    }

    @ViewBuilder private var title: some View {
        if let logoURL {
            PhoneImage(url: logoURL, contentMode: .fit, plate: false)
                .frame(width: 220, height: 84, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: meta.name))
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(verbatim: meta.name)
                .font(PhoneTheme.display(34, .semibold, relativeTo: .largeTitle))
                .foregroundStyle(BP.ink)
                .lines(2)
                .accessibilityAddTraits(.isHeader)
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
