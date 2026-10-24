import SwiftUI

/// Harbor Voyages (the TV's VoyageRoomView): choose a direction and a length, pick the next heading
/// a film at a time, then set sail. Everything is the shared `VoyageModel`; this is only the phone's layout.
struct PhoneVoyagePage: View {
    let open: (Meta) -> Void

    @StateObject private var model = VoyageModel()
    @State private var confirmEnd = false
    @State private var launching = false

    private var offline: Bool { Fixtures.active && !Fixtures.liveRooms }

    private var themes: [VoyageModel.Theme] { offline ? Self.fixtureThemes : model.themes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(T("Harbor Voyages"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if !offline { await model.load() } }
        .refreshable { if !offline { await model.refresh() } }
        .alert(T("End this voyage?"), isPresented: $confirmEnd) {
            Button(T("End voyage"), role: .destructive) { Task { await model.end() } }
            Button(T("Keep sailing"), role: .cancel) {}
        }
        .accessibilityIdentifier("voyage-page")
    }

    @ViewBuilder private var content: some View {
        if offline {
            chooser
        } else if let active = model.active {
            voyage(active)
        } else if model.loadFailed {
            ErrorPlate(title: T("Couldn't load Harbor Voyages right now.")) { Task { await model.load() } }
        } else if model.snapshot == nil {
            ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            chooser
        }
    }

    // MARK: Chooser

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: T("Plan a voyage"))
                    .font(PhoneTheme.display(26, .semibold, relativeTo: .title))
                    .foregroundStyle(BP.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: T("Pick a direction, then choose each film from three headings."))
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                    .foregroundStyle(BP.inkMuted)
                if let streak = model.snapshot?.streak, streak > 0 {
                    Text(verbatim: T("Streak: %lld", streak))
                        .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(BP.accent)
                }
            }
            .padding(.horizontal, PhoneTheme.margin)

            ChipRow {
                ForEach([3, 5, 7], id: \.self) { n in
                    GlassChip(title: TCount(n, one: "%lld film", "%lld films"), selected: model.length == n) {
                        model.length = n
                    }
                }
            }

            if let error = model.error {
                Text(verbatim: T(error))
                    .font(PhoneTheme.sans(14, .medium, relativeTo: .footnote))
                    .foregroundStyle(BP.danger)
                    .padding(.horizontal, PhoneTheme.margin)
                    .accessibilityIdentifier("voyage-error")
            }

            VStack(spacing: 10) {
                ForEach(themes) { theme in themeRow(theme) }
            }
            .padding(.horizontal, PhoneTheme.margin)
        }
    }

    private func themeRow(_ theme: VoyageModel.Theme) -> some View {
        let from: Color = PhoneTint.color(theme.from)
        let to: Color = PhoneTint.color(theme.to)
        return Button {
            if offline {
                PhoneToaster.shared.show(T("Voyages need the engine."))
            } else {
                PhoneFeedback.shared.success()
                Task { await model.start(theme) }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: T(theme.label))
                        .font(PhoneTheme.sans(18, .bold, relativeTo: .headline))
                    Text(verbatim: T(theme.tagline))
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .opacity(0.85)
                        .lines(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if model.busy == theme.id { ProgressView().tint(.white) }
            }
            .foregroundStyle(Color.white)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous)
                    .fill(LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .disabled(model.busy != nil)
        .accessibilityLabel(Text(verbatim: T(theme.label) + ". " + T(theme.tagline)))
        .accessibilityIdentifier("voyage-theme-\(theme.id)")
    }

    // MARK: A voyage under way

    private func voyage(_ a: VoyageModel.Active) -> some View {
        let accent: Color = PhoneTint.color(a.accent)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: T(a.themeLabel))
                    .font(PhoneTheme.display(26, .semibold, relativeTo: .title))
                    .foregroundStyle(accent)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: T(a.tagline))
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                    .foregroundStyle(BP.inkMuted)
                Text(verbatim: T("%lld of %lld films", a.picked, a.targetLength))
                    .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(BP.inkSubtle)
                    .accessibilityIdentifier("voyage-progress")
            }
            .padding(.horizontal, PhoneTheme.margin)

            slots(a.slots)

            if a.sailing {
                sailing(a)
            } else if a.ready {
                readyBlock(a)
            } else if a.stuck {
                stuckBlock
            } else {
                picker(a)
            }

            Button(role: .destructive) { confirmEnd = true } label: {
                Text(verbatim: T("End voyage")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, PhoneTheme.margin)
            .accessibilityIdentifier("voyage-end")
        }
    }

    private func slots(_ slots: [VoyageModel.Slot]) -> some View {
        VStack(spacing: 8) {
            ForEach(slots, id: \.index) { slot in
                HStack(spacing: 10) {
                    Image(systemName: slot.done ? "checkmark.circle.fill" : (slot.current ? "play.circle.fill" : "circle"))
                        .foregroundStyle(slot.done || slot.current ? BP.accent : BP.inkSubtle)
                        .accessibilityHidden(true)
                    Text(verbatim: slot.meta?.name ?? T("Not chosen yet"))
                        .font(PhoneTheme.sans(15, slot.current ? .bold : .medium, relativeTo: .callout))
                        .foregroundStyle(slot.meta == nil ? BP.inkSubtle : BP.ink)
                        .lines(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityIdentifier("voyage-slots")
    }

    private func picker(_ a: VoyageModel.Active) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: T("Choose your next heading"))
                .font(PhoneTheme.sans(17, .bold, relativeTo: .headline))
                .foregroundStyle(BP.ink)
                .padding(.horizontal, PhoneTheme.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: PhoneTheme.railGap) {
                    ForEach(a.headings) { meta in
                        PosterTile(meta: meta, width: 132) {
                            PhoneFeedback.shared.success()
                            Task {
                                await model.choose(meta)
                                await model.settle(meta)
                            }
                        }
                    }
                }
                .padding(.horizontal, PhoneTheme.margin)
                .phoneRailScaled()
            }
            HStack(spacing: 10) {
                Button { Task { await model.undo() } } label: { Text(verbatim: T("Undo")).frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                    .disabled(a.picked == 0)
                    .accessibilityIdentifier("voyage-undo")
                Button { Task { await model.reroll() } } label: { Text(verbatim: T("Shuffle")).frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("voyage-reroll")
            }
            .padding(.horizontal, PhoneTheme.margin)
        }
    }

    private func readyBlock(_ a: VoyageModel.Active) -> some View {
        Button {
            guard !launching else { return }
            launching = true
            PhoneFeedback.shared.success()
            Task {
                let first = await model.launch()
                launching = false
                if let first { open(first) }
            }
        } label: {
            Label(T("Set sail"), systemImage: "sailboat.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityIdentifier("voyage-launch")
    }

    @ViewBuilder private func sailing(_ a: VoyageModel.Active) -> some View {
        if let next = a.next {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: T("Up next"))
                    .font(PhoneTheme.sans(17, .bold, relativeTo: .headline))
                    .foregroundStyle(BP.ink)
                PosterTile(meta: next, width: 132) { open(next) }
            }
            .padding(.horizontal, PhoneTheme.margin)
        } else {
            Text(verbatim: T("Voyage complete."))
                .font(PhoneTheme.sans(16, .semibold, relativeTo: .callout))
                .foregroundStyle(BP.inkMuted)
                .padding(.horizontal, PhoneTheme.margin)
        }
    }

    private var stuckBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: T("This route ran out of headings."))
                .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                .foregroundStyle(BP.inkMuted)
            HStack(spacing: 10) {
                Button { Task { await model.undo() } } label: { Text(verbatim: T("Undo")).frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                Button { Task { await model.reroll() } } label: { Text(verbatim: T("Shuffle")).frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    /// The directions Discover offers under `--fixtures`, where the engine has no pool to chart.
    private static let fixtureThemes: [VoyageModel.Theme] = [
        VoyageModel.Theme(id: "fixture-noir", label: "Night Noir", tagline: "Rain, neon and a long way home.", type: "movie", genre: "Thriller",
                          accent: "#f59e0b", backdrop: nil, from: "#1e1b4b", to: "#0f172a"),
        VoyageModel.Theme(id: "fixture-feelgood", label: "Feel-good Fridays", tagline: "Funny, warm, and over by dinner.", type: "movie", genre: "Comedy",
                          accent: "#f97316", backdrop: nil, from: "#b45309", to: "#7c2d12"),
    ]
}

/// One genre's titles (the TV's genre grid): TMDB discover pages, 20 at a time, paged as the end nears.
struct PhoneGenrePage: View {
    let genre: String
    let offline: Bool
    let open: (Meta) -> Void

    @EnvironmentObject private var app: AppModel
    @State private var metas: [Meta] = []
    @State private var page = 0
    @State private var loading = false
    @State private var exhausted = false
    @State private var pageFailed = false
    @State private var note: String?
    @State private var started = false

    private struct Page: Decodable {
        @LossyArray var metas: [Meta]
        var status: String
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(verbatim: T(genre))
                    .font(PhoneTheme.display(28, .semibold, relativeTo: .title))
                    .foregroundStyle(BP.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, PhoneTheme.margin)
                    .accessibilityIdentifier("genre-title")
                if metas.isEmpty && started && !loading {
                    if pageFailed && note == nil {
                        ErrorPlate(title: T("Couldn't load this genre right now.")) { Task { await loadMore(retry: true) } }
                    } else {
                        EmptyState(title: note ?? T("Nothing in %@ right now.", T(genre)), systemImage: "film.stack")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: PhoneTheme.posterWidth), spacing: PhoneTheme.railGap, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        ForEach(metas) { meta in
                            PosterTile(meta: meta) { open(meta) }
                                .onAppear { if meta.id == metas.last?.id { Task { await loadMore() } } }
                        }
                    }
                    .padding(.horizontal, PhoneTheme.margin)
                    if loading { ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity) }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(T(genre))
        .navigationBarTitleDisplayMode(.inline)
        .task { if metas.isEmpty { await loadMore() } }
        .accessibilityIdentifier("genre-page")
    }

    /// `retry`: a Try again press; a page that failed is not read again on scroll alone.
    private func loadMore(retry: Bool = false) async {
        guard !loading, !exhausted, retry || !pageFailed else { return }
        loading = true
        defer { loading = false; started = true }
        if offline {
            // Under --fixtures the engine has no TMDB: the Home fixture rows stand in for the genre.
            let found: [BrowseRow] = (try? await app.browseSource.rows(for: .home)) ?? []
            metas = found.flatMap { $0.metas }.uniquedById()
            exhausted = true
            return
        }
        let p = ProfilesStore.shared.active
        let profileId: String = p?.id ?? "default"
        let linked: Bool = p?.linked ?? true
        let name: String = genre
        var next = page
        var got: Page = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [profileId, linked, name, next + 1])) ?? Page(metas: [], status: "failed")
        // A page the anime filter emptied is not the end: skip past it, a few times at most.
        var skipped = 0
        while got.status == "filtered", skipped < 3 {
            next += 1
            skipped += 1
            got = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [profileId, linked, name, next + 1])) ?? Page(metas: [], status: "failed")
        }
        guard !Task.isCancelled else { return }
        if got.status == "failed" {
            pageFailed = true
            if got.metas.isEmpty, metas.isEmpty { note = nil }
            return
        }
        pageFailed = false
        if got.metas.isEmpty {
            exhausted = true
            if metas.isEmpty {
                switch got.status {
                case "no-key": note = T("Genre shelves are built from TMDB. Add a key in Setup to fill this one.")
                case "filtered": note = T("Everything on this page of %@ is hidden by your anime filter.", T(name))
                default: note = T("Nothing in %@ right now.", T(name))
                }
            }
            return
        }
        note = nil
        page = next + 1
        metas = (metas + got.metas).uniquedById()
    }
}
