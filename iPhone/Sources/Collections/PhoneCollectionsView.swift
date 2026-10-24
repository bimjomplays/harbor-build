import SwiftUI

/// What the Collections grid pushes: one collection's page. The card rides along (a TMDB card holds
/// its titles already); the page reads the viewer's own ones from PhoneCollectionsStore by ref.
struct PhoneCollectionTarget: Hashable {
    var card: CollectionsModel.Card

    static func == (a: PhoneCollectionTarget, b: PhoneCollectionTarget) -> Bool { a.card.key == b.card.key }
    func hash(into hasher: inout Hasher) { hasher.combine(card.key) }
}

/// The Collections room under the Library tab's Collections chip: the
/// source chips the TV has (All / Mine / TMDB / TVDB), a two-column grid of 16:9 cards (cover art,
/// name, count), "New collection", and Edit, which turns the viewer's own collections into a list to
/// drag into order, rename and delete. A card pushes the collection's page.
/// The viewer's own collections come from PhoneCollectionsStore (the engine store the TV edits too);
/// TMDB franchises and TVDB lists come from the shared CollectionsModel, as on the TV.
struct PhoneCollectionsView: View {
    let views: ShellViewState
    @EnvironmentObject private var nav: PhoneNavigator
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var store = PhoneCollectionsStore.shared
    @StateObject private var model = CollectionsModel()
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var width: CGFloat = 0
    @State private var editMode: EditMode = .inactive
    @State private var naming = false
    @State private var draft = ""
    @State private var renaming: CollectionsModel.Card?
    @State private var deleting: CollectionsModel.Card?

    private static let sources: [(key: String, label: String)] = [("all", "All"), ("mine", "Mine"), ("tmdb", "TMDB"), ("tvdb", "TVDB")]
    private static let gap: CGFloat = 12

    /// Fixture runs (`--fixtures shell`) stay off the network: the curated sources show nothing.
    private var offline: Bool { Fixtures.active && !Fixtures.liveRooms }

    private var showsMine: Bool { model.source == "all" || model.source == "mine" }
    private var editing: Bool { editMode.isEditing }

    /// The cards the chosen source shows: the viewer's own first (from the store, in their order).
    private var cards: [CollectionsModel.Card] {
        let curated: [CollectionsModel.Card] = offline ? [] : model.cards.filter { $0.source != "mine" }
        switch model.source {
        case "mine": return store.mine
        case "all": return store.mine + curated
        default: return curated
        }
    }

    private var columnCount: Int { typeSize.isAccessibilitySize ? 1 : 2 }

    private var cardWidth: CGFloat {
        let available = (width > 0 ? width : 390) - PhoneTheme.margin * 2
        let columns = CGFloat(columnCount)
        return max(120, ((available - Self.gap * (columns - 1)) / columns).rounded(.down))
    }

    var body: some View {
        Group {
            if editing {
                editList
            } else {
                grid
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .toolbar {
            if showsMine && (!store.mine.isEmpty || editing) {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editing ? T("Done") : T("Edit")) {
                        PhoneFeedback.shared.selection()
                        withMotion { editMode = editing ? .inactive : .active }
                    }
                    .fontWeight(editing ? .semibold : .regular)
                    .accessibilityIdentifier("collections-edit")
                }
            }
        }
        .navigationDestination(for: PhoneCollectionTarget.self) { target in
            PhoneCollectionPage(card: target.card, open: { nav.open($0) })
        }
        // Read afresh each time the room opens (an edit on the TV shows here) and for each profile.
        .task(id: profiles.activeId) {
            await store.load()
            guard !model.loaded, !model.loading else { return }
            model.restore(source: views.collectionSource, category: views.collectionCategory)
            if !offline { await model.load() }
        }
        .onChange(of: model.source) { _, source in
            views.collectionSource = source
            if !showsMine { editMode = .inactive }
        }
        .onChange(of: model.category) { _, category in views.collectionCategory = category }
        .alert(T("New collection"), isPresented: $naming) {
            TextField(T("Name this collection"), text: $draft)
                .accessibilityIdentifier("collection-name-field")
            Button(T("Create")) {
                let name = draft
                Task {
                    guard let made = await store.create(name: name) else { return }
                    if model.source != "all" && model.source != "mine" { model.set(source: "mine") }
                    nav.push(PhoneCollectionTarget(card: made))
                }
            }
            Button(T("Cancel"), role: .cancel) {}
        }
        .alert(T("Rename"), isPresented: renameShown) {
            TextField(T("Name this collection"), text: $draft)
                .accessibilityIdentifier("collection-name-field")
            Button(T("Save")) {
                guard let card = renaming else { return }
                let name = draft
                Task { await store.rename(card.ref, to: name) }
            }
            Button(T("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(T("Delete this collection?"), isPresented: deleteShown, titleVisibility: .visible, presenting: deleting) { card in
            Button(T("Delete"), role: .destructive) {
                PhoneFeedback.shared.warning()
                Task { await store.delete(card.ref) }
            }
            .accessibilityIdentifier("collection-delete-confirm")
            Button(T("Cancel"), role: .cancel) {}
        } message: { card in
            Text(verbatim: card.name)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("collections-room")
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func startRename(_ card: CollectionsModel.Card) {
        PhoneFeedback.shared.tap()
        draft = card.name
        renaming = card
    }

    private func startCreate() {
        PhoneFeedback.shared.tap()
        draft = ""
        naming = true
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controls
                content
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable {
            await store.load()
            if !offline && !showsMine { await model.pull() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChipRow {
                ForEach(Self.sources, id: \.key) { source in
                    GlassChip(title: T(source.label), selected: model.source == source.key) {
                        guard model.source != source.key else { return }
                        PhoneFeedback.shared.selection()
                        model.set(source: source.key)
                    }
                }
            }
            .accessibilityIdentifier("collections-sources")
            if model.source == "tmdb" && !offline {
                if model.hasKey {
                    ChipRow {
                        ForEach(model.categories, id: \.self) { category in
                            GlassChip(title: T(category), selected: model.category == category) {
                                PhoneFeedback.shared.selection()
                                model.set(category: category)
                            }
                        }
                    }
                } else {
                    note(T("TMDB collections need a TMDB key. Add one in Settings."))
                }
            }
            if showsMine {
                HStack(spacing: 10) {
                    Button(action: startCreate) {
                        Label(T("New collection"), systemImage: "plus")
                            .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                    }
                    .buttonStyle(.glass)
                    .disabled(!store.canCreate)
                    .accessibilityIdentifier("collections-new")
                    Text(verbatim: "\(store.mine.count) / \(store.limits.collections)")
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(BP.inkSubtle)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, PhoneTheme.margin)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
            .foregroundStyle(BP.inkMuted)
            .padding(.horizontal, PhoneTheme.margin)
    }

    @ViewBuilder private var content: some View {
        let shown = cards
        if shown.isEmpty && (!store.loaded || (model.busy && !offline && !showsMine)) {
            skeleton
        } else if shown.isEmpty && store.failed && showsMine {
            ErrorPlate(title: T("Couldn't load this"), message: T("Check the connection and try again.")) {
                Task { await store.load() }
            }
        } else if shown.isEmpty && model.source == "mine" {
            EmptyState(title: T("Make your first collection"), message: T("You have not made a collection yet."),
                       systemImage: "rectangle.stack.badge.plus", actionTitle: T("New collection"), action: startCreate)
                .padding(.top, 12)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: Self.gap, alignment: .top), count: columnCount),
                      alignment: .leading, spacing: 16) {
                ForEach(shown) { card in
                    cell(card)
                        .onAppear {
                            if !offline && card.key == shown.last?.key && card.source != "mine" { Task { await model.pull() } }
                        }
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            if model.showAllTvdb && !offline {
                Button(T("See every TVDB list")) {
                    PhoneFeedback.shared.selection()
                    model.set(source: "tvdb")
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            }
            footer
        }
    }

    @ViewBuilder private func cell(_ card: CollectionsModel.Card) -> some View {
        let mine = card.source == "mine"
        let tile = PhoneCollectionCard(card: card, width: cardWidth) {
            PhoneFeedback.shared.tap()
            nav.push(PhoneCollectionTarget(card: card))
        }
        if mine {
            tile.contextMenu {
                Button { startRename(card) } label: { Label(T("Rename"), systemImage: "pencil") }
                if let at = store.mine.firstIndex(where: { $0.ref == card.ref }) {
                    if at > 0 {
                        Button {
                            Task { await store.move(fromOffsets: IndexSet(integer: at), toOffset: at - 1) }
                        } label: { Label(T("Move up"), systemImage: "arrow.up") }
                    }
                    if at < store.mine.count - 1 {
                        Button {
                            Task { await store.move(fromOffsets: IndexSet(integer: at), toOffset: at + 2) }
                        } label: { Label(T("Move down"), systemImage: "arrow.down") }
                    }
                }
                Button(role: .destructive) { deleting = card } label: { Label(T("Delete"), systemImage: "trash") }
            }
        } else {
            tile
        }
    }

    /// The end of the list, the TV's end line; a spinner while a curated source pages in.
    @ViewBuilder private var footer: some View {
        Group {
            if !offline && model.busy && !showsMineOnly {
                HStack(spacing: 8) {
                    ProgressView().tint(BP.inkSubtle)
                    Text(verbatim: T("Loading more collections...")).foregroundStyle(BP.inkSubtle)
                }
            } else if let line = endMessage {
                Text(verbatim: T(line)).foregroundStyle(BP.inkSubtle)
            }
        }
        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityIdentifier("collections-end")
    }

    private var showsMineOnly: Bool { model.source == "mine" }

    private var endMessage: String? {
        if model.source == "mine" || (offline && model.source == "all") {
            return store.mine.isEmpty ? "Nothing to show here yet." : "That's all of your collections."
        }
        if offline { return "Nothing to show here yet." }
        return model.done ? model.endMessage : nil
    }

    private var skeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: Self.gap, alignment: .top), count: columnCount),
                  alignment: .leading, spacing: 16) {
            ForEach(0..<(columnCount * 3), id: \.self) { _ in
                SkeletonBlock(width: cardWidth, height: cardWidth * 9 / 16, radius: PhoneTheme.radiusMedium)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityIdentifier("collections-loading")
    }

    // MARK: Edit mode

    /// The viewer's own collections as a list: drag a row by its handle to move it, the delete button
    /// (or a swipe) asks before deleting, a tap renames. The curated sources are not the viewer's to edit.
    private var editList: some View {
        List {
            Section {
                ForEach(store.mine) { card in
                    Button { startRename(card) } label: {
                        PhoneCollectionRow(card: card)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: card.name))
                    .accessibilityValue(Text(verbatim: PhoneCollectionCard.countLine(card)))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text(verbatim: T("Rename")))
                    .accessibilityIdentifier("collection-row-\(card.name)")
                }
                .onMove { source, destination in
                    PhoneFeedback.shared.selection()
                    Task { await store.move(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    guard let at = offsets.first, store.mine.indices.contains(at) else { return }
                    deleting = store.mine[at]
                }
            } footer: {
                Text(verbatim: T("Drag to reorder"))
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("collections-list")
    }
}

/// One collection in the grid: the cover under a scrim, the eyebrow (byline or "My collection"), the
/// name and the count line, as the TV's collection card reads it.
struct PhoneCollectionCard: View {
    let card: CollectionsModel.Card
    var width: CGFloat = 180
    let action: () -> Void

    /// bp-collection-card.tsx metaLine: "{count} items" (owned) / "{count} films" (TMDB) / "TVDB list".
    static func countLine(_ card: CollectionsModel.Card) -> String {
        switch card.source {
        case "mine":
            let n = card.items.count + (card.hidden ?? 0)
            return TCount(n, one: "%lld item", "%lld items")
        case "tvdb" where card.count == nil:
            return T("TVDB list")
        default:
            if let n = card.count { return T("%lld films", n) }
            return T("Collection")
        }
    }

    private var eyebrow: String {
        if let byline = card.byline, !byline.isEmpty { return byline }
        switch card.source {
        case "mine": return T("My collection")
        case "tvdb": return "TVDB"
        default: return "TMDB"
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.panel)
                if let image = card.image, !image.isEmpty {
                    PhoneImage(url: image).opacity(0.85)
                } else if card.source == "mine" {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(BP.inkSubtle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                LinearGradient(stops: [.init(color: BP.void_.opacity(0.92), location: 0),
                                       .init(color: BP.void_.opacity(0.44), location: 0.54),
                                       .init(color: .clear, location: 1)],
                               startPoint: .bottom, endPoint: .top)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: eyebrow)
                        .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(card.source == "mine" ? BP.accent : BP.inkSubtle)
                        .lines(1)
                    Text(verbatim: card.name)
                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: Self.countLine(card))
                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                        .foregroundStyle(BP.inkMuted)
                        .lines(1)
                }
                .padding(10)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: card.name))
        .accessibilityValue(Text(verbatim: Self.countLine(card)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("collection-\(card.name)")
    }
}

/// One of the viewer's collections in edit mode's list: a small cover, the name, the count.
struct PhoneCollectionRow: View {
    let card: CollectionsModel.Card

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BP.panel)
                if let image = card.image, !image.isEmpty { PhoneImage(url: image) }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.name)
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                Text(verbatim: PhoneCollectionCard.countLine(card))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
