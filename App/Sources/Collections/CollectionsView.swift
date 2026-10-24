import SwiftUI


struct CollectionsView: View {
    @Environment(\.shellFocusNamespace) private var shellNS
    @Namespace private var localNS
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = CollectionsModel()
    @State private var open: CollectionsModel.Card?
    @State private var detail: Meta?
    @State private var naming = false
    @State private var nameDraft = ""
    /// One Create at a time: a double press made two collections.
    @State private var creating = false
    @FocusState private var focus: String?

    private static let sources: [(String, String)] = [("all", "All"), ("mine", "Mine"), ("tmdb", "TMDB"), ("tvdb", "TVDB")]
    /// Six 404 pt cards (2 559 pt with the gaps) ran far off the 1 632 pt page.
    /// bp-collections GRID_COLUMNS (minmax(196px, 1fr), gap 11.4) lays four ~234 px columns across
    /// the 969 px page: four cards of px(230) = 387 pt, 1 629 pt with the gaps.
    static let cardWidth = BP.px(230)
    private static let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: BP.px(16)), count: 4)

    /// SH-1: the focused card's own cover, read back off `focus` (no extra state to keep in step).
    private var focusedMeta: Meta? {
        guard let focus, focus.hasPrefix("card:") else { return nil }
        let key = String(focus.dropFirst("card:".count))
        return model.cards.first { $0.key == key }?.meta
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground(focused: focusedMeta)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text("Collections").font(BP.display(36)).foregroundStyle(BP.ink)
                    sourceRow
                    // Only beside its "New collection" button (All / Mine): left
                    // open under Community, TMDB or TVDB, its Cancel aimed the ring at a button no
                    // longer drawn, and the ring fell off the page.
                    if naming && canCreate { nameRow }
                    if model.source == "tmdb" {
                        // bp-collection-steps categories: Sagas, Superheroes, Action…
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: BP.px(8)) {
                                ForEach(model.categories, id: \.self) { c in Button(c) { model.set(category: c) }.buttonStyle(BPActionStyle(primary: model.category == c)).bpSelected(model.category == c) }
                            }
                            .padding(.vertical, BP.px(4))
                        }
                        .scrollClipDisabled()
                        .focusSection()
                        if !model.hasKey { BPNote(text: "TMDB collections need a TMDB key. Add one in Settings.") }
                    }
                    if model.busy && model.cards.isEmpty { ProgressView().tint(BP.inkMuted) }
                    if let f = model.failed { BPNote(text: f, tone: BP.danger) }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(20)) {
                        ForEach(model.cards) { c in
                            Button { open = c } label: { CollectionCardView(card: c) }
                                .onAppear { if c.key == model.cards.last?.key { Task { await model.pull() } } }
                                .buttonStyle(BPTileStyle())
                                .focused($focus, equals: "card:" + c.key)
                                .accessibilityIdentifier("collection-\(c.key)")
                                // bp-collection-card.tsx aria-label={entry.name}: just the name, not the
                                // byline/count line too.
                                .accessibilityLabel(Text(verbatim: c.name))
                        }
                        if model.showAllTvdb {
                            // bp-collections showAllTvdb: the card unmounts under the ring, which goes to the TVDB chip.
                            Button {
                                model.set(source: "tvdb")
                                DispatchQueue.main.async { focus = "source:tvdb" }
                            } label: { CollectionMoreCard(label: T("See every TVDB list")) }
                                .buttonStyle(BPTileStyle())
                        }
                    }
                    .padding(.vertical, BP.px(14))
                    .prefersDefaultFocus(true, in: shellNS ?? localNS)
                    .focusSection()
                    if model.busy && !model.cards.isEmpty {
                        HStack(spacing: BP.px(8)) {
                            ProgressView().tint(BP.inkSubtle)
                            Text("Loading more collections...").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
                        }
                        .frame(maxWidth: .infinity)
                    } else if model.done {
                        Text(T(model.endMessage)).font(BP.sans(13)).foregroundStyle(BP.inkSubtle).frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The overlay is drawn over the room, not presented: the grid under it kept
            // the ring (the pressed card stayed focused behind the overlay, and Select opened it
            // again). bp-collection-items is a dialog; the room takes no focus while it is up.
            .disabled(open != nil)
            if let c = open {
                CollectionItemsOverlay(card: c, limits: model.limits, onClose: {
                    let key = c.key
                    open = nil
                    Task {
                        await model.reloadMine()
                        restoreFocus(to: key)
                    }
                }, onChanged: { source in
                    Task { await model.reloadMine() }
                }, onOpen: { item in detail = item.meta }, topInset: BP.barHeight + BP.px(20))
                .id(c.key)
                .transition(.opacity)
            }
        }
        // `.task` re-runs whenever a title's cover closes (and on every return to the
        // tab): a full load reset the TMDB / TVDB grid each time. Later passes refresh "Mine" only.
        .task {
            if model.loaded || model.loading { await model.reloadMine(); return }
            // (open-items sweep 2) bp-collections useBpPersistedState("collectionSource" /
            // "collectionCategory"): the room is built afresh on every tab switch and came back on
            // All each time.
            model.restore(source: app.views.collectionSource, category: app.views.collectionCategory)
            await model.load()
        }
        .onChange(of: model.source) { _, s in app.views.collectionSource = s }
        .onChange(of: model.category) { _, c in app.views.collectionCategory = c }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .animation(BP.easeFast, value: open?.key)
        // The overlay keeps the focus while it is up: the shell's bar takes none and LB/RB
        // turn no tab (the room under it is disabled above). Cleared when the room goes.
        .onAppear { app.roomLayer = open != nil }
        .onDisappear { app.roomLayer = false }
        .onChange(of: open?.key) { _, key in app.roomLayer = key != nil }
    }

    /// The sources that show "New collection" (and its name row).
    private var canCreate: Bool { model.source == "all" || model.source == "mine" }

    private var sourceRow: some View {
        HStack(spacing: BP.px(8)) {
            ForEach(Self.sources, id: \.0) { key, label in
                Button(T(label)) { model.set(source: key) }
                    .buttonStyle(BPActionStyle(primary: model.source == key)).bpSelected(model.source == key)
                    .focused($focus, equals: "source:" + key)
                    .accessibilityIdentifier("collections-source-" + key)
            }
            if canCreate {
                // community-hub.tsx: "New collection", with the "{n} / {max}" count beside it.
                Button { nameDraft = ""; naming.toggle() } label: { Label("New collection", systemImage: "plus") }
                    .buttonStyle(BPActionStyle(primary: naming))
                    .disabled(model.mine.count >= model.limits.collections)
                    .focused($focus, equals: "new")
                    .accessibilityIdentifier("collections-new")
                Text("\(model.mine.count) / \(model.limits.collections)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            Text("\(model.cards.count) collections").font(BP.sans(13)).foregroundStyle(BP.inkMuted).padding(.leading, BP.px(8))
        }
        // The section spans the page: without the Community chip the row ends left of the
        // Collections tab, so Down from that tab missed it and, over an empty grid (no keys, no
        // collections of one's own), the ring could not leave the bar.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var nameRow: some View {
        HStack(alignment: .bottom, spacing: BP.px(8)) {
            BPField(label: "Name", placeholder: "Name this collection", text: $nameDraft)
                .frame(maxWidth: BP.px(520))
            Button("Create") {
                guard !creating else { return }
                creating = true
                let name = nameDraft
                Task {
                    let c = await model.create(name: name)
                    creating = false
                    if let c { naming = false; open = c }
                }
            }
            .buttonStyle(BPActionStyle(primary: true, busy: creating))
            .accessibilityIdentifier("collections-create")
            // The row goes with Cancel: the ring returns to "New collection" instead of falling off.
            Button("Cancel") { naming = false; focus = "new" }.buttonStyle(BPActionStyle())
                .accessibilityIdentifier("collections-cancel")
        }
        .focusSection()
        // Back inside the row closes it like Cancel (the overlay's panels do the
        // same); it left the room for Home with the row and its draft still open.
        .onExitCommand { naming = false; focus = "new" }
    }

    /// bp-collection-items cleanup: the ring goes back to the card that opened the overlay, or to the
    /// source chip when that card is gone (a deleted collection).
    @MainActor private func restoreFocus(to key: String) {
        let target: String = model.cards.contains(where: { $0.key == key }) ? "card:" + key : "source:" + model.source
        DispatchQueue.main.async { focus = target }
    }
}

struct CollectionCardView: View {
    let card: CollectionsModel.Card

    /// bp-collection-card.tsx metaLine: byline · "{count} items" (owned) / "{count} films" (TMDB) / "TVDB list".
    private var line: String {
        var bits: [String] = []
        if let b = card.byline, !b.isEmpty { bits.append(b) }
        if card.source == "mine" {
            if let n = card.count { bits.append(T("%lld items", n)) }
        } else if let n = card.count {
            bits.append(T("%lld films", n))
        } else if card.source == "tvdb" {
            bits.append(T("TVDB list"))
        } else {
            bits.append(T("Collection"))
        }
        return bits.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: card.image)
                    .accessibilityHidden(true)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                    Text(line).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                }
                .padding(BP.px(10))
            }
            .frame(width: CollectionsView.cardWidth, height: (CollectionsView.cardWidth * 9 / 16).rounded())
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        }
    }
}

/// bp-collection-card.tsx BpCollectionMoreCard.
struct CollectionMoreCard: View {
    let label: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel2)
            VStack(spacing: BP.px(8)) {
                Image(systemName: "arrow.forward.circle").font(.system(size: BP.px(26), weight: .semibold)).foregroundStyle(BP.inkMuted).accessibilityHidden(true)
                Text(label).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).multilineTextAlignment(.center)
            }
            .padding(BP.px(12))
        }
        .frame(width: CollectionsView.cardWidth, height: (CollectionsView.cardWidth * 9 / 16).rounded())
    }
}
