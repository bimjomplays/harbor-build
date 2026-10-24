import SwiftUI

/// The Library tab's Library room: Saved, Watchlist, In progress and
/// Watched as a segmented control, glass chips for type, sort and the tab's groups, and the titles
/// as a poster grid (three across, two at large text) or a list whose rows swipe to Remove and to
/// mark a film watched or unwatched. My Lists, Favorites and every connected service are in the
/// More menu with Search, Refresh, Stats, library repair and Letterboxd, as the TV's chip row
/// offers them. A tap opens the title page; a long press is the menu every poster has.
struct PhoneLibraryView: View {
    let views: ShellViewState
    let open: (Meta) -> Void
    @StateObject private var model: PhoneLibraryModel
    @ObservedObject private var actions = PhoneTitleActions.shared
    @ObservedObject private var marks = CardMarksStore.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0
    @State private var searching = false
    @State private var draft = ""
    @State private var statsEnabled = false
    @State private var repairOpen = false
    @State private var letterboxdOpen = false
    @State private var storyOpen = false
    /// A top title tapped in the story: opened once the story is down.
    @State private var fromStory: Meta?

    init(views: ShellViewState, open: @escaping (Meta) -> Void) {
        self.views = views
        self.open = open
        _model = StateObject(wrappedValue: PhoneLibraryModel(tab: views.libraryTab, offline: Fixtures.active && !Fixtures.liveRooms,
                                                             failing: PhoneLaunch.libraryFail))
    }

    private static let gap: CGFloat = 12

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

    /// What is on screen: the feed's sections, split for In progress / Watched, less what was removed.
    private var sections: [LibraryModel.Section] {
        model.sections(watchedOverrides: actions.watchedOverride, dismissed: actions.dismissed)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .topLeading) { orderMarker }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        // Runs again when the story or a pushed title page closes.
        .task {
            await model.start()
            await loadStatsGate()
        }
        .onChange(of: model.filter) { _, filter in views.libraryTab = filter.engineTab }
        .sheet(isPresented: $repairOpen) {
            PhoneLibraryRepairSheet { Task { await model.reload(force: true) } }
        }
        // A Letterboxd connected or disconnected there adds or drops its tab.
        .sheet(isPresented: $letterboxdOpen, onDismiss: { Task { await model.start() } }) {
            PhoneLetterboxdSheet()
        }
        .fullScreenCover(isPresented: $storyOpen, onDismiss: {
            guard let meta = fromStory else { return }
            fromStory = nil
            open(meta)
        }) {
            PhoneWrappedStory(offline: model.offline, close: { storyOpen = false }) { meta in
                fromStory = meta
                storyOpen = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library")
    }

    /// views/library.tsx "Stats" behind settings.wrappedButton (always there under fixtures).
    private func loadStatsGate() async {
        if model.offline {
            statsEnabled = true
            return
        }
        let p = ProfilesStore.shared.active
        statsEnabled = (try? await HarborEngine.shared.call("wrapped.enabled", [p?.id ?? "default", p?.linked ?? true]) as Bool) ?? false
    }

    private func select(_ filter: PhoneLibraryFilter) {
        guard filter != model.filter else { return }
        PhoneFeedback.shared.selection()
        if !filter.splitsHistory || !model.filter.splitsHistory {
            searching = false
            draft = ""
        }
        model.select(filter)
    }

    /// One invisible element with the titles on screen in order ("Dune: Part Two|Past Lives|..."), so a
    /// UI test can read the sort without walking a lazy grid. Only under `--fixtures`: VoiceOver
    /// would land on it.
    @ViewBuilder private var orderMarker: some View {
        let names: [String] = Fixtures.active ? sections.flatMap { $0.items.map(\.meta.name) } : []
        if !names.isEmpty {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: TCount(names.count, one: "%lld title", "%lld titles")))
                .accessibilityValue(Text(verbatim: names.joined(separator: "|")))
                .accessibilityIdentifier("library-order")
        }
    }

    // MARK: Controls

    private var segment: Binding<PhoneLibraryFilter?> {
        Binding(
            get: { model.filter.isSegment ? model.filter : nil },
            set: { next in if let next { select(next) } }
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(T("Library"), selection: segment) {
                ForEach(PhoneLibraryFilter.segments) { filter in
                    Text(verbatim: filter.label).tag(PhoneLibraryFilter?.some(filter))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, PhoneTheme.margin)
            .accessibilityIdentifier("library-filters")
            filterRow
            if searching { searchField }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if !model.filter.isSegment {
                        // A menu tab is on: its chip, lit, goes back to Saved.
                        GlassChip(title: model.label(of: model.filter), systemImage: "xmark", selected: true) { select(.saved) }
                    }
                    typeMenu
                    sortMenu
                    if let groups = model.feed?.groups, !groups.isEmpty { groupMenu(groups) }
                    layoutButton
                    countLabel
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("library-filter-row")
    }

    private var typeTitle: String {
        switch model.type {
        case "movie": return T("Movies")
        case "series": return T("Shows")
        default: return T("Type")
        }
    }

    private var typeBinding: Binding<String> {
        Binding(get: { model.type }, set: { t in
            PhoneFeedback.shared.selection()
            model.set(type: t)
        })
    }

    private var typeMenu: some View {
        FilterMenu(title: typeTitle, active: model.type != "all", identifier: "library-type", systemImage: "line.3.horizontal.decrease") {
            Picker(T("Type"), selection: typeBinding) {
                Text(verbatim: T("All")).tag("all")
                Text(verbatim: T("Movies")).tag("movie")
                Text(verbatim: T("Shows")).tag("series")
            }
        }
    }

    private var sortTitle: String {
        if model.ownedTab {
            return Self.ownedSorts.first { $0.id == model.ownedSort }?.label ?? T("Sort")
        }
        switch model.sort {
        case "title": return T("A-Z")
        case "year": return T("Year")
        default: return T("Recent")
        }
    }

    private struct Choice: Identifiable {
        let id: String
        let label: String
    }

    /// bp-library OWNED_SORTS (Media Servers).
    private static var ownedSorts: [Choice] {
        [Choice(id: "added", label: T("Date added")), Choice(id: "title", label: T("Title")), Choice(id: "year", label: T("Year")),
         Choice(id: "rating", label: T("Rating")), Choice(id: "runtime", label: T("Duration"))]
    }

    private var sortBinding: Binding<String> {
        Binding(get: { model.sort }, set: { s in
            PhoneFeedback.shared.selection()
            model.set(sort: s)
        })
    }

    private var ownedSortBinding: Binding<String> {
        Binding(get: { model.ownedSort }, set: { k in model.set(ownedSort: k) })
    }

    private var directionBinding: Binding<String> {
        Binding(get: { model.sortDir }, set: { d in model.set(sortDir: d) })
    }

    private var flatBinding: Binding<Bool> {
        Binding(get: { model.flat }, set: { on in if on != model.flat { model.toggleFlat() } })
    }

    /// bp-library: the View row only for the Recent sort with a dated title, outside the owned tab.
    private var showsGrouping: Bool {
        !model.offline && !model.ownedTab && model.sort == "recent" && (model.feed?.dated ?? false)
    }

    private var sortMenu: some View {
        FilterMenu(title: sortTitle, active: false, identifier: "library-sort", systemImage: "arrow.up.arrow.down") {
            if model.ownedTab {
                Picker(T("Sort"), selection: ownedSortBinding) {
                    ForEach(Self.ownedSorts) { choice in Text(verbatim: choice.label).tag(choice.id) }
                }
                Picker(T("Direction"), selection: directionBinding) {
                    Text(verbatim: T("Ascending")).tag("asc")
                    Text(verbatim: T("Descending")).tag("desc")
                }
            } else {
                Picker(T("Sort"), selection: sortBinding) {
                    Text(verbatim: T("Recent")).tag("recent")
                    Text(verbatim: T("A-Z")).tag("title")
                    // bp-library `sorts`: Year only while a shown title has a release year.
                    if model.feed?.years ?? true { Text(verbatim: T("Year")).tag("year") }
                }
            }
            if showsGrouping {
                Picker(T("View"), selection: flatBinding) {
                    Text(verbatim: T("Grouped")).tag(false)
                    Text(verbatim: T("One list")).tag(true)
                }
            }
        }
    }

    private var groupBinding: Binding<String?> {
        Binding(get: { model.group }, set: { g in
            PhoneFeedback.shared.selection()
            model.set(group: g)
        })
    }

    private func groupMenu(_ groups: [LibraryModel.Group]) -> some View {
        let picked: String? = groups.first { $0.id == model.group }.map { T($0.label) }
        return FilterMenu(title: picked ?? model.label(of: model.filter), active: model.group != nil, identifier: "library-group") {
            Picker(model.label(of: model.filter), selection: groupBinding) {
                Text(verbatim: T("All")).tag(String?.none)
                ForEach(groups) { g in
                    Text(verbatim: T(g.label)).tag(String?.some(g.id))
                }
            }
        }
    }

    private var layoutButton: some View {
        let grid = model.layout == .grid
        return Button {
            PhoneFeedback.shared.selection()
            withMotion(.easeOut(duration: 0.2)) { model.layout = grid ? .list : .grid }
        } label: {
            Image(systemName: grid ? "list.bullet" : "square.grid.3x2")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(BP.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassEffect(Glass.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: grid ? T("Show as list") : T("Show as grid")))
        .accessibilityIdentifier("library-layout")
    }

    /// bp-library: "{n} titles" while there are any (no "0 titles" over an empty tab). A split view
    /// counts its own half; the others the engine's match count.
    @ViewBuilder private var countLabel: some View {
        let shown: Int = sections.reduce(0) { $0 + $1.items.count }
        let n: Int = model.filter.splitsHistory ? shown : (model.feed?.matched ?? 0)
        if n > 0 {
            Text(verbatim: TCount(n, one: "%lld title", "%lld titles"))
                .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                .foregroundStyle(BP.inkMuted)
                .padding(.leading, 4)
                .accessibilityIdentifier("library-count")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(BP.inkMuted).accessibilityHidden(true)
            TextField(T("Search title"), text: $draft)
                .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { model.search(draft) }
                .accessibilityLabel(Text(verbatim: T("Search your library")))
                .accessibilityIdentifier("library-search-field")
            if !draft.isEmpty || !model.query.isEmpty {
                Button {
                    draft = ""
                    model.search("")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BP.inkMuted)
                }
                .accessibilityLabel(Text(verbatim: T("Clear")))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, PhoneTheme.margin)
    }

    // MARK: More menu

    private var moreMenu: some View {
        Menu {
            Button {
                searching.toggle()
                if !searching && !model.query.isEmpty {
                    draft = ""
                    model.search("")
                }
            } label: {
                Label(T("Search"), systemImage: "magnifyingglass")
            }
            Button {
                Task { await model.reload(force: true) }
            } label: {
                Label(T("Refresh"), systemImage: "arrow.clockwise")
            }
            if !model.menuTabs.isEmpty {
                Section {
                    ForEach(model.menuTabs) { tab in
                        Button {
                            select(.tab(tab.id))
                        } label: {
                            if model.filter == .tab(tab.id) {
                                Label(T(tab.label), systemImage: "checkmark")
                            } else {
                                Text(verbatim: T(tab.label))
                            }
                        }
                    }
                }
            }
            Section {
                if statsEnabled {
                    Button { storyOpen = true } label: { Label(T("Stats"), systemImage: "chart.bar") }
                }
                Button { repairOpen = true } label: { Label(T("Repair library"), systemImage: "wrench.and.screwdriver") }
                Button { letterboxdOpen = true } label: { Label(T("Letterboxd"), systemImage: "film.stack") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(Text(verbatim: T("More")))
        .accessibilityIdentifier("library-menu")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let shown = sections
        if let feed = model.feed {
            if shown.isEmpty {
                ScrollView {
                    switch PhoneLibraryQuery.nothingShown(status: feed.status, hasMore: feed.hasMore) {
                    case .error:
                        ErrorPlate(title: errorText) { Task { await model.reload(force: true) } }
                            .padding(.top, 24)
                    case .paging:
                        pager.padding(.top, 24)
                    case .empty:
                        empty(feed)
                    }
                }
                .refreshable { await model.reload(force: true) }
            } else if model.layout == .grid {
                grid(shown, feed: feed)
            } else {
                list(shown, feed: feed)
            }
        } else if model.loading {
            skeleton
        } else {
            ScrollView {
                ErrorPlate(title: errorText) { Task { await model.reload(force: true) } }
                    .padding(.top, 24)
            }
        }
    }

    /// bp-library.tsx emptyCopy: a service tab names the service it could not reach.
    private var errorText: String {
        let names = ["trakt": "Trakt", "anilist": "AniList", "mal": "MyAnimeList", "simkl": "Simkl", "letterboxd": "Letterboxd"]
        if let name = names[model.filter.engineTab] { return T("Couldn't reach %@. Try refreshing.", name) }
        return T("Couldn't load your library. Try refreshing.")
    }

    /// bp-library.tsx emptyCopy per tab (the TV's lines). In progress and Watched split History: a
    /// history with titles only in the other half is not "no matches".
    private func emptyCopy(_ f: LibraryModel.Feed) -> String {
        if model.loading && model.refreshing { return T("Loading…") }
        if model.narrowed || (!model.filter.splitsHistory && f.total > 0) { return T("No matches for these filters.") }
        switch model.filter {
        case .saved where !f.signedIn: return T("Sign in to Stremio or connect Trakt in Settings to see your library here.")
        case .inProgress where !f.signedIn, .watched where !f.signedIn:
            return T("Sign in to Stremio or connect Trakt in Settings to see what you have been watching.")
        case .saved: return T("Nothing saved yet. Add a title from any details page.")
        case .watchlist: return T("Your watchlist is empty.")
        case .inProgress: return T("Nothing here yet.")
        case .watched: return T("Nothing watched yet. Press play on something.")
        case .tab("lists"): return T("You have no lists yet.")
        case .tab("favorites") where f.hidden > 0:
            return T("Your %lld character and manga favorites live on the desktop Favorites tab.", f.hidden)
        case .tab("favorites"): return T("No favorites yet. Save a movie or show to see it here.")
        case .tab: return T("Nothing here yet.")
        }
    }

    private func empty(_ f: LibraryModel.Feed) -> some View {
        let narrowed: Bool = model.narrowed
        return EmptyState(title: model.label(of: model.filter), message: emptyCopy(f),
                          systemImage: narrowed ? "line.3.horizontal.decrease.circle" : "books.vertical",
                          actionTitle: narrowed ? T("Clear filters") : nil) {
            draft = ""
            model.clearFilters()
        }
        .padding(.top, 24)
    }

    private var skeleton: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.gap, alignment: .top), count: columnCount),
                      alignment: .leading, spacing: 16) {
                ForEach(0..<(columnCount * 3), id: \.self) { _ in
                    SkeletonBlock(width: cellWidth, height: cellWidth * 1.5)
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.top, 12)
        }
        .scrollDisabled(true)
        .accessibilityIdentifier("library-loading")
    }

    // MARK: Grid

    private struct GridRow: Identifiable {
        let id: String
        let first: Bool
        let entries: [LibraryModel.Entry]
    }

    private static func rows(of section: LibraryModel.Section, columns: Int) -> [GridRow] {
        let columns = max(1, columns)
        let items = section.items
        return stride(from: 0, to: items.count, by: columns).map { start in
            GridRow(id: "\(section.id)#\(start / columns)", first: start == 0,
                    entries: Array(items[start..<min(start + columns, items.count)]))
        }
    }

    // As on the catalog page, the rows are the lazy stack's own children, never a LazyVGrid inside it
    //.
    private func grid(_ shown: [LibraryModel.Section], feed: LibraryModel.Feed) -> some View {
        let tileWidth = cellWidth
        let columns = columnCount
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if feed.status == "error" { errorNote }
                ForEach(shown) { section in
                    if !section.label.isEmpty {
                        SectionHeader(title: T(section.label))
                            .padding(.top, 20)
                    }
                    ForEach(Self.rows(of: section, columns: columns)) { row in
                        HStack(alignment: .top, spacing: Self.gap) {
                            ForEach(row.entries) { entry in tile(entry, width: tileWidth) }
                        }
                        .padding(.horizontal, PhoneTheme.margin)
                        .padding(.top, row.first ? 10 : 16)
                    }
                }
                if feed.hasMore { pager }
                Color.clear.frame(height: 24)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await model.reload(force: true) }
        .accessibilityIdentifier("library-grid")
    }

    private func tile(_ entry: LibraryModel.Entry, width: CGFloat) -> some View {
        let meta = entry.meta
        let progress: Double = entry.progress ?? 0
        let showsBar = progress > 0 && progress < 1 && !watched(entry)
        return PosterTile(meta: meta, width: width) { open(meta) }
            .overlay(alignment: .topLeading) {
                if showsBar {
                    ProgressBar(value: progress)
                        .frame(width: width - 16)
                        .offset(x: 8, y: width * 1.5 - 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .phoneContextMenu(for: meta, fromContinueWatching: model.filter == .inProgress, open: open)
    }

    /// The feed came back with an error over titles already shown (bp-library keeps them).
    private var errorNote: some View {
        Text(verbatim: errorText)
            .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
            .foregroundStyle(BP.danger)
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.top, 8)
            .accessibilityIdentifier("library-error-note")
    }

    /// Under the last title while the engine has more: reports whether it is on screen, and the model
    /// asks for the next 60 (once per page).
    private var pager: some View {
        ProgressView()
            .tint(BP.inkMuted)
            .frame(maxWidth: .infinity, minHeight: 80)
            .onAppear { model.setEndInView(true) }
            .onDisappear { model.setEndInView(false) }
            .accessibilityIdentifier("library-more")
    }

    // MARK: List

    private func watched(_ entry: LibraryModel.Entry) -> Bool {
        actions.watchedOverride[entry.meta.id] ?? (entry.watched == true || marks.byId[entry.meta.id]?.watched != nil)
    }

    private func list(_ shown: [LibraryModel.Section], feed: LibraryModel.Feed) -> some View {
        List {
            if feed.status == "error" {
                errorNote.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(shown) { section in
                Section {
                    ForEach(section.items) { entry in row(entry) }
                } header: {
                    if !section.label.isEmpty {
                        Text(verbatim: T(section.label))
                            .font(PhoneTheme.display(20, .semibold, relativeTo: .title3))
                            .foregroundStyle(BP.ink)
                            .textCase(nil)
                    }
                }
            }
            if feed.hasMore {
                pager.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.reload(force: true) }
        .accessibilityIdentifier("library-list")
    }

    private func row(_ entry: LibraryModel.Entry) -> some View {
        let meta = entry.meta
        let removal = PhoneLibraryQuery.removal(for: model.filter, entry: entry)
        let isWatched = watched(entry)
        let progress: Double = entry.progress ?? 0
        return Button {
            PhoneFeedback.shared.tap()
            open(meta)
        } label: {
            HStack(spacing: 12) {
                PhoneImage(url: meta.poster)
                    .frame(width: 52, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: meta.name)
                        .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                    if !meta.facts.isEmpty {
                        Text(verbatim: meta.facts)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                            .lines(1)
                    }
                    if progress > 0 && progress < 1 && !isWatched {
                        ProgressBar(value: progress).frame(maxWidth: 160)
                    } else if isWatched {
                        Label(T("Watched"), systemImage: "checkmark.circle.fill")
                            .font(PhoneTheme.sans(12, .medium, relativeTo: .caption))
                            .foregroundStyle(BP.live)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: PhoneTheme.margin, bottom: 8, trailing: PhoneTheme.margin))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: meta.name))
        .accessibilityValue(Text(verbatim: rowValue(entry, watched: isWatched)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("row-\(entry.key)")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if removal != nil {
                Button(role: .destructive) {
                    PhoneFeedback.shared.tap()
                    Task { await model.remove(entry) }
                } label: {
                    Label(T("Remove"), systemImage: "trash")
                }
                .accessibilityIdentifier("swipe-remove")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if actions.canMarkWatched(meta) {
                Button {
                    let current = isWatched
                    Task { await PhoneTitleActions.shared.toggleWatched(meta, current: current) }
                } label: {
                    Label(isWatched ? T("Unwatched") : T("Watched"), systemImage: isWatched ? "eye.slash" : "checkmark.circle")
                }
                .tint(isWatched ? BP.inkMuted : BP.live)
                .accessibilityIdentifier("swipe-watched")
            }
        }
        .phoneContextMenu(for: meta, fromContinueWatching: model.filter == .inProgress, open: open)
    }

    /// The row's VoiceOver value: bpProgressValue's "{n}% watched" (1–99 % only), or Watched.
    private func rowValue(_ entry: LibraryModel.Entry, watched: Bool) -> String {
        if watched { return T("Watched") }
        let pct: Int = clampedInt(((entry.progress ?? 0) * 100).rounded())
        return pct >= 1 && pct <= 99 ? T("%lld%% watched", pct) : ""
    }
}

/// A resume bar: how far into the title the viewer is.
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(BP.ink.opacity(0.25))
                Capsule().fill(BP.accent).frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
