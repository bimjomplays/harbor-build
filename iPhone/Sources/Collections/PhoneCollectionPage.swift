import SwiftUI

/// One collection's page: the eyebrow, name, count and overview over a
/// poster grid, three across (two at accessibility sizes). The viewer's own collection adds Edit
/// (drag its titles into order, delete them) and a menu: Add titles, Rename, Delete. A TMDB
/// franchise reads its films when it came without them (a Home collection tile), a TVDB list reads
/// its entries (bp-collection.tsx), as the TV's overlays do.
struct PhoneCollectionPage: View {
    let card: CollectionsModel.Card
    let open: (Meta) -> Void
    var identifier = "collection-page"

    @ObservedObject private var store = PhoneCollectionsStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var fetched: CollectionsModel.Card?
    @State private var fetching = false
    @State private var fetchFailed = false
    @State private var width: CGFloat = 0
    @State private var editMode: EditMode = .inactive
    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var adding = false

    private static let gap: CGFloat = 12
    private var offline: Bool { Fixtures.active && !Fixtures.liveRooms }
    private var isMine: Bool { card.source == "mine" }
    private var editing: Bool { editMode.isEditing }

    /// The viewer's own collection as the store has it now (nil once deleted); any other as read.
    private var current: CollectionsModel.Card? {
        isMine ? store.card(card.ref) : (fetched ?? card)
    }

    private var items: [CollectionsModel.Item] { current?.items ?? [] }

    private var columnCount: Int {
        if typeSize.isAccessibilitySize { return 2 }
        if typeSize >= .xxxLarge && width > 0 && width < 400 { return 2 }
        return 3
    }

    private var cellWidth: CGFloat {
        let available = (width > 0 ? width : 390) - PhoneTheme.margin * 2
        let columns = CGFloat(columnCount)
        return max(80, ((available - Self.gap * (columns - 1)) / columns).rounded(.down))
    }

    var body: some View {
        Group {
            if editing {
                editList
            } else {
                page
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(PhoneBackground())
        .navigationTitle(current?.name ?? card.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if isMine && current != nil { mineToolbar } }
        .task { await fetchIfNeeded() }
        .alert(T("Rename"), isPresented: $renaming) {
            TextField(T("Name this collection"), text: $draft)
                .accessibilityIdentifier("collection-name-field")
            Button(T("Save")) {
                let name = draft
                let ref = card.ref
                Task { await store.rename(ref, to: name) }
            }
            Button(T("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(T("Delete this collection?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(T("Delete"), role: .destructive) {
                PhoneFeedback.shared.warning()
                let ref = card.ref
                dismiss()
                Task { await store.delete(ref) }
            }
            .accessibilityIdentifier("collection-delete-confirm")
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: current?.name ?? card.name)
        }
        .sheet(isPresented: $adding) {
            PhoneCollectionAddSheet(ref: card.ref) { adding = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Toolbar (the viewer's own)

    @ToolbarContentBuilder private var mineToolbar: some ToolbarContent {
        if editing || !items.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? T("Done") : T("Edit")) {
                    PhoneFeedback.shared.selection()
                    withMotion { editMode = editing ? .inactive : .active }
                }
                .fontWeight(editing ? .semibold : .regular)
                .accessibilityIdentifier("collection-edit")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    PhoneFeedback.shared.tap()
                    adding = true
                } label: { Label(T("Add titles"), systemImage: "plus") }
                .accessibilityIdentifier("collection-add")
                Button {
                    PhoneFeedback.shared.tap()
                    draft = current?.name ?? card.name
                    renaming = true
                } label: { Label(T("Rename"), systemImage: "pencil") }
                .accessibilityIdentifier("collection-rename")
                Button(role: .destructive) {
                    confirmDelete = true
                } label: { Label(T("Delete"), systemImage: "trash") }
                .accessibilityIdentifier("collection-delete")
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel(Text(verbatim: T("Edit collection")))
            }
            .accessibilityIdentifier("collection-menu")
        }
    }

    // MARK: Page

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// bp-collection-items: eyebrow (byline or "My collection"), name, "{count} items";
    /// bp-collection-detail: "Collection", name, "{count} films", overview.
    private var header: some View {
        let shown = current ?? card
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: isMine ? (shown.byline ?? T("My collection")) : T("Collection"))
                .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(BP.accent)
            Text(verbatim: shown.name)
                .font(PhoneTheme.display(30, .semibold, relativeTo: .largeTitle))
                .foregroundStyle(BP.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("collection-title")
            if let line = countLine(shown) {
                Text(verbatim: line)
                    .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(BP.inkMuted)
                    .accessibilityIdentifier("collection-count")
            }
            if let description = shown.description, !description.isEmpty {
                Text(verbatim: description)
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .body))
                    .foregroundStyle(BP.inkMuted)
                    .lines(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countLine(_ card: CollectionsModel.Card) -> String? {
        switch card.source {
        case "mine": return TCount(card.items.count + (card.hidden ?? 0), one: "%lld item", "%lld items")
        default: return card.items.isEmpty ? nil : T("%lld films", card.items.count)
        }
    }

    /// One row of the grid: up to `columnCount` titles side by side (rows, not a LazyVGrid, as on
    /// the catalog page).
    private struct GridRow: Identifiable {
        let id: Int
        let items: [CollectionsModel.Item]
    }

    @ViewBuilder private var content: some View {
        if isMine && current == nil {
            // Deleted (here, or on the TV while this page was open).
            EmptyState(title: T("Nothing to show here yet."), systemImage: "rectangle.stack")
                .padding(.top, 24)
        } else if items.isEmpty && fetching {
            ProgressView()
                .tint(BP.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if items.isEmpty {
            empty
        } else {
            let columns = max(1, columnCount)
            let rows: [GridRow] = stride(from: 0, to: items.count, by: columns).map { start in
                GridRow(id: start / columns, items: Array(items[start..<min(start + columns, items.count)]))
            }
            let tileWidth = cellWidth
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(row.items) { item in
                        let meta = item.meta
                        PosterTile(meta: meta, width: tileWidth) { open(meta) }
                            .phoneContextMenu(for: meta, open: open)
                    }
                }
                .padding(.horizontal, PhoneTheme.margin)
                .padding(.top, 16)
            }
        }
    }

    @ViewBuilder private var empty: some View {
        switch card.source {
        case "mine":
            EmptyState(title: T("This collection is empty."), message: T("Search movies, shows, and manga to add"),
                       systemImage: "rectangle.stack.badge.plus", actionTitle: T("Add titles")) {
                adding = true
            }
            .padding(.top, 24)
        case "tmdb" where !fetchFailed:
            EmptyState(title: T("No films found in this collection."), systemImage: "film.stack")
                .padding(.top, 24)
        default:
            if offline {
                EmptyState(title: T("Couldn't load this collection right now."), systemImage: "wifi.exclamationmark")
                    .padding(.top, 24)
            } else {
                ErrorPlate(title: T("Couldn't load this collection right now.")) {
                    Task { await fetchIfNeeded(retry: true) }
                }
                .padding(.top, 24)
            }
        }
    }

    // MARK: Edit mode (the viewer's own)

    private var editList: some View {
        List {
            Section {
                ForEach(items) { item in
                    PhoneCollectionItemRow(item: item)
                        .accessibilityIdentifier("collection-item-\(item.id)")
                }
                .onMove { source, destination in
                    PhoneFeedback.shared.selection()
                    let ref = card.ref
                    Task { await store.moveItems(in: ref, fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    let ref = card.ref
                    Task { await store.removeItems(atOffsets: offsets, from: ref) }
                }
            } header: {
                Text(verbatim: T("In this collection"))
            } footer: {
                Text(verbatim: T("Drag to reorder"))
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("collection-list")
    }

    // MARK: Reading a curated collection

    private func fetchIfNeeded(retry: Bool = false) async {
        guard !isMine, !offline, !fetching else { return }
        guard retry || fetched == nil else { return }
        let p = ProfilesStore.shared.active
        switch card.source {
        case "tmdb" where card.items.isEmpty:
            fetching = true
            defer { fetching = false }
            let got: CollectionsModel.Card? = try? await HarborEngine.shared.call("collectionsRoom.tmdbCard", [p?.id ?? "default", p?.linked ?? true, card.ref, card.name])
            fetchFailed = got == nil
            if let got { fetched = got }
        case "tvdb":
            fetching = true
            defer { fetching = false }
            struct Detail: Decodable { var name: String; var overview: String?; var image: String?; @LossyArray var items: [CollectionsModel.Item]; var failed: Bool }
            let got: Detail? = try? await HarborEngine.shared.call("collectionsRoom.tvdbDetail", [card.ref, card.name])
            fetchFailed = got?.failed ?? true
            if let got, !got.failed {
                var next = card
                next.name = got.name
                next.description = got.overview ?? card.description
                next.image = got.image ?? card.image
                next.items = got.items
                next.count = got.items.count
                fetched = next
            }
        default:
            break
        }
    }
}

/// One title of a collection in edit mode's list.
struct PhoneCollectionItemRow: View {
    let item: CollectionsModel.Item

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BP.panel)
                PhoneImage(url: item.poster)
            }
            .frame(width: 36, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            Text(verbatim: item.name)
                .font(PhoneTheme.sans(16, .medium, relativeTo: .body))
                .foregroundStyle(BP.ink)
                .lines(2)
            Spacer(minLength: 0)
        }
        // Its own label: in edit mode a combined one took the delete button's ("Remove, …", and the
        // handle read "Reorder Remove", run 39187156648).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.name))
    }
}
