import SwiftUI

/// The pages the Home editor pushes.
enum PhoneHomeEditorPage: Hashable {
    /// A row's own page, by spec id.
    case row(String)
    case add
    case hero
}

extension HomeLayoutLoader {
    /// The name the editor lists a row by: the viewer's own, else the source's, else the one it was
    /// added under.
    func editorTitle(_ spec: HomeRowSpec) -> String {
        if let own = spec.title, !own.isEmpty { return own }
        if let entry = HomeSourceRegistry.entry(for: spec.source, in: snapshot) { return entry.title }
        if let saved = spec.savedTitle, !saved.isEmpty { return saved }
        return T("A row this version can't show")
    }

    /// Why a row showed nothing on the last pass; nil when it showed (or nothing has loaded yet).
    func skipReason(_ specId: String) -> HomeContent.SkipReason? {
        guard case .loaded(let content) = phase else { return nil }
        return content.skipped.first { $0.specId == specId }?.reason
    }

    /// The entry's icon, or a plain one for a source this pass did not list.
    func editorIcon(_ source: HomeRowSource) -> String {
        HomeSourceRegistry.entry(for: source, in: snapshot)?.systemImage ?? "questionmark.square.dashed"
    }
}

/// "Edit Home": the hero, the rows top to bottom, a row's own settings, and the picker
/// that adds any row Harbor can show. Every change is saved for the active profile as it is made, and
/// Home behind the sheet follows at once. Swipe a row to remove it; "Reorder" shows the drag handles.
struct PhoneHomeEditor: View {
    @ObservedObject var loader: HomeLayoutLoader
    let close: () -> Void

    @State private var path: [PhoneHomeEditorPage] = []
    @State private var editMode: EditMode = .inactive
    @State private var confirmReset = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                heroSection
                rowsSection
                Section {
                    NavigationLink(value: PhoneHomeEditorPage.add) {
                        Label(T("Add a row"), systemImage: "plus.circle.fill")
                            .font(PhoneTheme.sans(17, .semibold, relativeTo: .body))
                    }
                    .accessibilityIdentifier("home-editor-add")
                }
                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label(T("Reset to the standard Home"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(loader.layout.isDefault)
                    .accessibilityIdentifier("home-editor-reset")
                    .confirmationDialog(T("Reset Home?"), isPresented: $confirmReset, titleVisibility: .visible) {
                        Button(T("Reset"), role: .destructive) {
                            PhoneFeedback.shared.success()
                            editMode = .inactive
                            loader.resetLayout()
                        }
                        .accessibilityIdentifier("home-editor-reset-confirm")
                        Button(T("Cancel"), role: .cancel) {}
                    } message: {
                        Text(verbatim: T("The hero and rows go back to the standard Home for this profile."))
                    }
                } footer: {
                    Text(verbatim: T("Each profile keeps its own Home on this iPhone."))
                }
            }
            .environment(\.editMode, $editMode)
            .scrollContentBackground(.hidden)
            .background(PhoneBackground())
            .navigationTitle(T("Edit Home"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? T("Done Reordering") : T("Reorder")) {
                        PhoneFeedback.shared.selection()
                        withMotion { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .disabled(loader.layout.rows.count < 2 && !editMode.isEditing)
                    .accessibilityIdentifier("home-editor-reorder")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T("Done"), action: close)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("home-editor-done")
                }
            }
            .navigationDestination(for: PhoneHomeEditorPage.self) { page in
                switch page {
                case .row(let id):
                    PhoneHomeRowDetail(loader: loader, specId: id)
                case .add:
                    PhoneHomeSourcePicker(loader: loader)
                case .hero:
                    PhoneHomeHeroPicker(loader: loader)
                }
            }
        }
        .tint(BP.accent)
        // Every room page, both trackers and every addon's catalog list, so the picker lists them all.
        .task { await loader.loadAllSources() }
        .presentedCover("home-edit")
        .accessibilityIdentifier("home-editor")
    }

    // MARK: Hero

    private var heroSection: some View {
        Section {
            NavigationLink(value: PhoneHomeEditorPage.hero) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BP.accent)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(T("Hero"))
                        .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                    Spacer(minLength: 8)
                    Text(verbatim: heroName)
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                        .lines(1)
                }
            }
            .accessibilityIdentifier("home-editor-hero")
        } footer: {
            Text(verbatim: T("The big carousel at the top of Home."))
        }
    }

    private var heroName: String {
        switch loader.layout.hero {
        case .auto:
            return T("Automatic")
        case .off:
            return T("Off")
        case .source(let source):
            if let spec = loader.layout.rows.first(where: { $0.source == source }) { return loader.editorTitle(spec) }
            return HomeSourceRegistry.entry(for: source, in: loader.snapshot)?.title ?? T("A row that's gone")
        }
    }

    // MARK: Rows

    private var rowsSection: some View {
        Section {
            if loader.layout.rows.isEmpty {
                Text(verbatim: T("Home has no rows. Add one below."))
                    .foregroundStyle(.secondary)
            }
            ForEach(loader.layout.rows) { spec in
                NavigationLink(value: PhoneHomeEditorPage.row(spec.id)) {
                    rowCell(spec)
                }
                .accessibilityIdentifier("home-row-\(loader.editorTitle(spec))")
            }
            .onMove { from, to in
                PhoneFeedback.shared.selection()
                loader.edit { $0.move(fromOffsets: from, toOffset: to) }
            }
            .onDelete { offsets in
                PhoneFeedback.shared.warning()
                loader.edit { $0.remove(atOffsets: offsets) }
            }
        } header: {
            Text(verbatim: T("Rows"))
        } footer: {
            Text(verbatim: T("Tap a row to rename it, change its tiles or show it in the hero. Swipe to remove it; Reorder to drag rows up and down."))
        }
    }

    private func rowCell(_ spec: HomeRowSpec) -> some View {
        let note = status(spec)
        return HStack(spacing: 14) {
            Image(systemName: loader.editorIcon(spec.source))
                .font(.body.weight(.semibold))
                .foregroundStyle(BP.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: loader.editorTitle(spec))
                    .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                    .lines(1)
                if !note.text.isEmpty {
                    Text(verbatim: note.text)
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(note.warn ? Color.orange : Color.secondary)
                        .lines(1)
                }
            }
            Spacer(minLength: 8)
            if loader.layout.hero == .source(spec.source) {
                Image(systemName: "sparkles")
                    .foregroundStyle(BP.accent)
                    .accessibilityLabel(Text(verbatim: T("In the hero")))
            }
        }
        .padding(.vertical, 2)
    }

    /// What the row is (its page or service), or why it showed nothing on the last pass.
    private func status(_ spec: HomeRowSpec) -> (text: String, warn: Bool) {
        let entry = HomeSourceRegistry.entry(for: spec.source, in: loader.snapshot)
        if entry?.availability == .needsSignIn { return (T("Not signed in"), true) }
        switch loader.skipReason(spec.id) {
        case .some(.unavailable):
            return (spec.source.isKnown ? T("Not available right now") : T("Made by a newer Harbor"), true)
        case .some(.failed):
            return (T("Couldn't load"), true)
        case .some(.duplicate):
            return (T("Already on Home above"), true)
        case .some(.empty):
            return (T("Nothing to show right now"), false)
        case .none:
            break
        }
        guard let entry else { return ("", false) }
        // A renamed row says where it comes from.
        if let own = spec.title, !own.isEmpty { return (entry.title, false) }
        return (entry.subtitle ?? entry.group.title, false)
    }
}

// MARK: - A row's page

/// One row's settings: its name, its tiles, how many titles it shows, the hero, its place, and removing it.
struct PhoneHomeRowDetail: View {
    @ObservedObject var loader: HomeLayoutLoader
    let specId: String

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var spec: HomeRowSpec? { loader.layout.rows.first { $0.id == specId } }

    var body: some View {
        Group {
            if let spec {
                form(spec)
            } else {
                EmptyState(title: T("This row is gone"), systemImage: "rectangle.stack")
                    .padding(.top, 40)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(spec.map { loader.editorTitle($0) } ?? T("Row"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = spec?.title ?? "" }
        .onDisappear(perform: saveName)
        .accessibilityIdentifier("home-row-detail")
    }

    private func form(_ spec: HomeRowSpec) -> some View {
        let index: Int = loader.layout.index(of: specId) ?? 0
        let isHero = loader.layout.hero == .source(spec.source)
        let room: HomeRoom? = { if case .engineRoom(let r) = spec.source { return r } else { return nil } }()
        return List {
            // A whole page's rows keep their own names.
            if room == nil {
                Section {
                    TextField(sourceTitle(spec), text: $name)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                        .onSubmit(saveName)
                        .accessibilityIdentifier("home-row-name")
                } header: {
                    Text(verbatim: T("Name"))
                } footer: {
                    Text(verbatim: T("Leave it empty to use the row's own name."))
                }
            }
            if showsLook(spec) {
                Section {
                    Picker(T("Tiles"), selection: shapeBinding) {
                        Text(verbatim: T("Automatic")).tag(TileShape?.none)
                        Text(verbatim: T("Posters")).tag(TileShape?.some(.poster))
                        Text(verbatim: T("Wide")).tag(TileShape?.some(.wide))
                        Text(verbatim: T("Top 10 numbers")).tag(TileShape?.some(.rank))
                    }
                    .accessibilityIdentifier("home-row-style")
                    Picker(T("Show"), selection: limitBinding) {
                        Text(verbatim: T("Every title")).tag(Int?.none)
                        Text(verbatim: T("10 titles")).tag(Int?.some(10))
                        Text(verbatim: T("20 titles")).tag(Int?.some(20))
                    }
                    .accessibilityIdentifier("home-row-limit")
                } header: {
                    Text(verbatim: T("Look"))
                } footer: {
                    if room != nil {
                        Text(verbatim: T("Service, addon and collection rows keep their own tiles."))
                    }
                }
            }
            Section {
                Button {
                    PhoneFeedback.shared.selection()
                    let source = spec.source
                    loader.edit { $0.hero = isHero ? .auto : .source(source) }
                } label: {
                    Label(isHero ? T("Shown in the hero") : T("Show in the hero"),
                          systemImage: isHero ? "checkmark.circle.fill" : "sparkles.rectangle.stack")
                }
                .accessibilityIdentifier("home-row-hero")
                Button {
                    move(by: -1)
                } label: {
                    Label(T("Move up"), systemImage: "arrow.up")
                }
                .disabled(index == 0)
                .accessibilityIdentifier("home-row-up")
                Button {
                    move(by: 1)
                } label: {
                    Label(T("Move down"), systemImage: "arrow.down")
                }
                .disabled(index >= loader.layout.rows.count - 1)
                .accessibilityIdentifier("home-row-down")
                if let room {
                    Button {
                        split(room)
                    } label: {
                        Label(T("Split into separate rows"), systemImage: "rectangle.split.1x2")
                    }
                    .disabled((loader.snapshot.pages[room]?.rows ?? []).isEmpty)
                    .accessibilityIdentifier("home-row-split")
                }
            } footer: {
                if room != nil {
                    Text(verbatim: T("Split lists each of this page's rows on its own, so you can move or remove them one by one."))
                }
            }
            Section {
                Button(role: .destructive) {
                    remove()
                } label: {
                    Label(T("Remove from Home"), systemImage: "trash")
                }
                .accessibilityIdentifier("home-row-remove")
            }
        }
    }

    /// The source's own name, the placeholder of the name field.
    private func sourceTitle(_ spec: HomeRowSpec) -> String {
        HomeSourceRegistry.entry(for: spec.source, in: loader.snapshot)?.title ?? spec.savedTitle ?? T("Name")
    }

    /// Continue Watching draws its own cards, and a service / addon / collection band its own tiles.
    private func showsLook(_ spec: HomeRowSpec) -> Bool {
        switch spec.source {
        case .continueWatching, .unknown:
            return false
        case .engineRow(let room, let key):
            guard let shape = loader.snapshot.pages[room]?.rows.first(where: { $0.key == key })?.shape else { return true }
            return shape != .brand && shape != .collection
        default:
            return true
        }
    }

    private var shapeBinding: Binding<TileShape?> {
        Binding(
            get: { spec?.options.shape },
            set: { shape in
                guard var options = spec?.options, options.shape != shape else { return }
                PhoneFeedback.shared.selection()
                options.shape = shape
                let id = specId
                loader.edit { $0.setOptions(id: id, options) }
            }
        )
    }

    private var limitBinding: Binding<Int?> {
        Binding(
            get: { spec?.options.limit },
            set: { limit in
                guard var options = spec?.options, options.limit != limit else { return }
                PhoneFeedback.shared.selection()
                options.limit = limit
                let id = specId
                loader.edit { $0.setOptions(id: id, options) }
            }
        )
    }

    private func saveName() {
        guard let spec else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (spec.title ?? "") else { return }
        let id = specId
        loader.edit { $0.rename(id: id, to: trimmed) }
    }

    private func move(by delta: Int) {
        PhoneFeedback.shared.selection()
        let id = specId
        loader.edit { _ = $0.move(id: id, by: delta) }
    }

    private func split(_ room: HomeRoom) {
        PhoneFeedback.shared.success()
        let rows: [BrowseRow] = loader.snapshot.pages[room]?.rows ?? []
        let id = specId
        loader.edit { _ = $0.expandRoom(id: id, rows: rows) }
        dismiss()
    }

    private func remove() {
        PhoneFeedback.shared.warning()
        let id = specId
        loader.edit { _ = $0.remove(id: id) }
        dismiss()
    }
}

// MARK: - Adding a row

/// Every row Harbor can show, by where it comes from: Home, Movies, Shows and Anime (Continue Watching,
/// the whole page, or one of its rows), the AniList and MyAnimeList lists, and each addon's catalogs.
/// A row already on Home is ticked; one that needs a sign-in says so; one hidden for this profile is
/// not listed.
struct PhoneHomeSourcePicker: View {
    @ObservedObject var loader: HomeLayoutLoader

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Shelf: Identifiable {
        let group: HomeSourceEntry.Group
        let entries: [HomeSourceEntry]
        var id: String { group.rawValue }
    }

    private var shelves: [Shelf] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed: [HomeSourceEntry] = loader.entries.filter { entry in
            guard entry.availability != .unavailable else { return false }
            guard !wanted.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(wanted)
                || (entry.subtitle ?? "").localizedCaseInsensitiveContains(wanted)
                || entry.group.title.localizedCaseInsensitiveContains(wanted)
        }
        return HomeSourceEntry.Group.allCases.compactMap { group in
            let entries = listed.filter { $0.group == group }
            return entries.isEmpty ? nil : Shelf(group: group, entries: entries)
        }
    }

    var body: some View {
        let shelves = self.shelves
        List {
            if loader.readingAllSources {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(verbatim: T("Looking for more rows…"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("home-source-reading")
            }
            ForEach(shelves) { shelf in
                Section {
                    ForEach(shelf.entries) { entry in
                        sourceRow(entry)
                    }
                } header: {
                    Text(verbatim: shelf.group.title)
                }
            }
        }
        .overlay {
            if shelves.isEmpty && !loader.readingAllSources {
                if query.isEmpty {
                    ContentUnavailableView(T("No rows to add"), systemImage: "rectangle.stack",
                                           description: Text(verbatim: T("Pull down on Home to refresh, then try again.")))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(verbatim: T("Search rows")))
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Add a row"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("home-source-picker")
    }

    private func sourceRow(_ entry: HomeSourceEntry) -> some View {
        let onHome = loader.layout.contains(entry.source)
        let addable = entry.availability == .available && !onHome
        return Button {
            add(entry)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: entry.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BP.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.title)
                        .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                        .foregroundStyle(addable ? Color.primary : Color.secondary)
                    if let note = note(entry, onHome: onHome) {
                        Text(verbatim: note)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: onHome ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(addable ? BP.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!addable)
        .accessibilityIdentifier("home-source-\(entry.title)")
    }

    private func note(_ entry: HomeSourceEntry, onHome: Bool) -> String? {
        if onHome { return T("On your Home") }
        if entry.availability == .needsSignIn { return T("Not signed in") }
        if case .engineRow(let room, _) = entry.source, loader.layout.contains(.engineRoom(room)) {
            return T("Shown with its page's rows; adding it gives it a place of its own")
        }
        return entry.subtitle
    }

    private func add(_ entry: HomeSourceEntry) {
        PhoneFeedback.shared.success()
        let source = entry.source
        let title = entry.title
        loader.edit { _ = $0.insert(source, savedTitle: title) }
        dismiss()
    }
}

// MARK: - The hero

/// What the hero shows: Automatic (the Home page's own picks, else the first row's titles), Off, or
/// the titles of any one row, on Home or not.
struct PhoneHomeHeroPicker: View {
    @ObservedObject var loader: HomeLayoutLoader

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let hero = loader.layout.hero
        let onHome: [HomeRowSpec] = loader.layout.rows.filter { $0.source.isKnown }
        let others: [HomeSourceEntry] = loader.entries.filter { $0.availability == .available && !loader.layout.contains($0.source) }
        List {
            Section {
                option(T("Automatic"), detail: T("The Home page's picks, or your first row's titles"),
                       systemImage: "wand.and.stars", id: "home-hero-auto", chosen: hero == .auto) { choose(.auto) }
                option(T("Off"), detail: T("Home starts with its first row"),
                       systemImage: "rectangle.slash", id: "home-hero-off", chosen: hero == .off) { choose(.off) }
            }
            if !onHome.isEmpty {
                Section {
                    ForEach(onHome) { spec in
                        let title = loader.editorTitle(spec)
                        option(title, detail: nil, systemImage: loader.editorIcon(spec.source),
                               id: "home-hero-\(title)", chosen: hero == .source(spec.source)) { choose(.source(spec.source)) }
                    }
                } header: {
                    Text(verbatim: T("From your Home"))
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { entry in
                        option(entry.title, detail: entry.subtitle ?? entry.group.title, systemImage: entry.systemImage,
                               id: "home-hero-\(entry.title)", chosen: hero == .source(entry.source)) { choose(.source(entry.source)) }
                    }
                } header: {
                    Text(verbatim: T("Other rows"))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Hero"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("home-hero-picker")
    }

    private func option(_ title: String, detail: String?, systemImage: String, id: String, chosen: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BP.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                        .foregroundStyle(Color.primary)
                    if let detail {
                        Text(verbatim: detail)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BP.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func choose(_ hero: HomeHeroSource) {
        PhoneFeedback.shared.selection()
        loader.edit { $0.hero = hero }
        dismiss()
    }
}
