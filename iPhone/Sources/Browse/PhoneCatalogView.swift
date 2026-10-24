import SwiftUI

/// The poster-grid page behind "See all", a streaming service and an installed addon
///: three posters across (two at accessibility text sizes, or at large text
/// on a narrow phone), glass chips pinned under the bar for the shelf, genre, year and sort, and a
/// grid that reads the next page as the end comes into view.
struct PhoneCatalogPage: View {
    let title: String
    var logo: String? = nil
    /// The page's identifier, so a UI test can tell which route opened.
    let identifier: String
    let open: (Meta) -> Void
    @StateObject private var model: PhoneCatalogModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0

    init(origin: PhoneCatalogModel.Origin, title: String, logo: String? = nil, identifier: String, open: @escaping (Meta) -> Void) {
        self.title = title
        self.logo = logo
        self.identifier = identifier
        self.open = open
        _model = StateObject(wrappedValue: PhoneCatalogModel(origin: origin))
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    content
                } header: {
                    controls
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(PhoneBackground())
        .overlay(alignment: .topLeading) { progressMarker }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// One invisible accessibility element outside the lazy stack: it always exists while titles show,
    /// reads "<n> titles" (what the headline says) and carries the value "end" once the list is complete.
    /// A UI test follows the loading through it instead of querying cells of the big lazy grid.
    @ViewBuilder private var progressMarker: some View {
        if !model.metas.isEmpty {
            let ended = !model.canLoadMore && !model.pageFailed
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: TCount(model.visible.count, one: "%lld title", "%lld titles")))
                .accessibilityValue(Text(verbatim: ended ? "end" : "more"))
                .accessibilityIdentifier("catalog-progress")
        }
    }

    // MARK: Pinned controls

    @ViewBuilder private var controls: some View {
        if model.shelves.count > 1 || !model.metas.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if model.shelves.count > 1 {
                    ChipRow {
                        ForEach(model.shelves) { shelf in
                            GlassChip(title: shelf.title, selected: shelf.id == model.active?.id) {
                                PhoneFeedback.shared.selection()
                                model.choose(shelf)
                            }
                        }
                    }
                    .accessibilityIdentifier("catalog-shelves")
                }
                if !model.metas.isEmpty { filterRow }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if !model.genres.isEmpty {
                        FilterMenu(title: model.filters.genre ?? T("Genre"), active: model.filters.genre != nil, identifier: "filter-genre") {
                            Picker(T("Genre"), selection: $model.filters.genre) {
                                Text(verbatim: T("All genres")).tag(String?.none)
                                ForEach(model.genres, id: \.self) { genre in
                                    Text(verbatim: genre).tag(String?.some(genre))
                                }
                            }
                        }
                    }
                    if !model.years.isEmpty {
                        FilterMenu(title: model.filters.year ?? T("Year"), active: model.filters.year != nil, identifier: "filter-year") {
                            Picker(T("Year"), selection: $model.filters.year) {
                                Text(verbatim: T("Any year")).tag(String?.none)
                                ForEach(model.years, id: \.self) { year in
                                    Text(verbatim: year).tag(String?.some(year))
                                }
                            }
                        }
                    }
                    FilterMenu(title: model.filters.sort == .source ? T("Sort") : model.filters.sort.label,
                               active: model.filters.sort != .source, identifier: "filter-sort", systemImage: "arrow.up.arrow.down") {
                        Picker(T("Sort"), selection: $model.filters.sort) {
                            ForEach(PhoneCatalogModel.Sort.allCases, id: \.self) { sort in
                                Text(verbatim: sort.label).tag(sort)
                            }
                        }
                    }
                    if model.filters.isActive {
                        GlassChip(title: T("Clear"), systemImage: "xmark") {
                            PhoneFeedback.shared.selection()
                            model.filters.genre = nil
                            model.filters.year = nil
                        }
                    }
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("catalog-filters")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.shelvesFailed {
            ErrorPlate(title: T("Couldn't load this"), message: T("Check the connection and try again.")) {
                model.reloadShelves()
            }
            .padding(.top, 24)
        } else if model.metas.isEmpty && (model.loading || !model.shelvesLoaded) {
            skeleton
        } else if model.metas.isEmpty && model.pageFailed {
            ErrorPlate(title: T("Couldn't load this"), message: T("Check the connection and try again.")) {
                model.requestMore(retry: true)
            }
            .padding(.top, 24)
        } else if model.metas.isEmpty {
            EmptyState(title: T("Nothing here yet"), message: model.emptyNote ?? T("No titles came back for this list."),
                       systemImage: "rectangle.stack",
                       actionTitle: model.active == nil ? nil : T("Try again")) {
                if let shelf = model.active { model.choose(shelf) }
            }
            .padding(.top, 24)
        } else {
            loaded
        }
    }

    /// One row of the grid: up to `columnCount` titles side by side.
    private struct GridRow: Identifiable {
        let id: Int
        let metas: [Meta]
    }

    private static func rows(of metas: [Meta], columns: Int) -> [GridRow] {
        let columns = max(1, columns)
        return stride(from: 0, to: metas.count, by: columns).map { start in
            GridRow(id: start / columns, metas: Array(metas[start..<min(start + columns, metas.count)]))
        }
    }

    // The rows are the lazy stack's own children, never a LazyVGrid inside it: a lazy grid nested in
    // the pinned lazy stack is measured by estimate, and when the footer changed at the end of the
    // 42-title list mid-scroll the two kept re-measuring each other and the main thread never left
    // layout. Every row has the same height, so the stack's own estimate holds.
    @ViewBuilder private var loaded: some View {
        let shown: [Meta] = model.visible
        let rows: [GridRow] = Self.rows(of: shown, columns: columnCount)
        let tileWidth = cellWidth
        headline(count: shown.count)
        if shown.isEmpty && model.filters.isActive {
            EmptyState(title: T("No matches"),
                       message: model.exhausted ? T("Nothing in this list fits those filters.") : T("Nothing loaded so far fits those filters."),
                       systemImage: "line.3.horizontal.decrease.circle",
                       actionTitle: T("Clear filters")) {
                model.filters.genre = nil
                model.filters.year = nil
            }
            .padding(.top, 12)
        }
        ForEach(rows) { row in
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(row.metas) { meta in
                    PosterTile(meta: meta, width: tileWidth) { open(meta) }
                        .phoneContextMenu(for: meta, open: open)
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.top, row.id == 0 ? 8 : 16)
            // The last rows coming near ask for the next page, so the end of the list never waits on the footer.
            .onAppear { if row.id >= rows.count - 2 { model.requestMore() } }
        }
        footer
    }

    private func headline(count: Int) -> some View {
        HStack(spacing: 8) {
            if let logo, !logo.isEmpty {
                PhoneImage(url: logo, contentMode: .fit, plate: false)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(verbatim: TCount(count, one: "%lld title", "%lld titles"))
                .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                .foregroundStyle(BP.inkMuted)
                .accessibilityIdentifier("catalog-count")
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 8)
    }

    /// Below the grid: a spinner while there is more, a Try again, or the end. One view whatever it
    /// shows, at one height for the spinner and the end, so the last swap does not move the list. It only
    /// reports whether it is in view; the model decides when to read (a filter can hide a whole page).
    private var footer: some View {
        ZStack {
            if model.pageFailed {
                VStack(spacing: 10) {
                    Text(verbatim: T("Couldn't load more titles."))
                        .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                        .foregroundStyle(BP.inkMuted)
                    Button(T("Try again")) { model.requestMore(retry: true) }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("catalog-retry")
                }
                .padding(.vertical, 16)
            } else if model.canLoadMore {
                ProgressView()
                    .tint(BP.inkMuted)
                    .accessibilityIdentifier("catalog-more")
            } else {
                Text(verbatim: T("That's everything."))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkSubtle)
                    .accessibilityIdentifier("catalog-end")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .onAppear { model.setEndInView(true) }
        .onDisappear { model.setEndInView(false) }
    }

    private var skeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.gap, alignment: .top), count: columnCount),
                  alignment: .leading, spacing: 16) {
            ForEach(0..<(columnCount * 3), id: \.self) { _ in
                SkeletonBlock(width: cellWidth, height: cellWidth * 1.5)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 12)
        .accessibilityIdentifier("catalog-loading")
    }
}

/// A glass chip that opens a menu of choices (genre, year, sort); tinted while it holds a choice.
struct FilterMenu<Choices: View>: View {
    let title: String
    let active: Bool
    let identifier: String
    var systemImage: String? = nil
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        let glass: Glass = active ? Glass.regular.tint(BP.accent).interactive() : Glass.regular.interactive()
        Menu {
            choices()
        } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.footnote.weight(.semibold))
                }
                Text(verbatim: title).font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(active ? BP.on : BP.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(glass, in: .capsule)
        }
        .accessibilityIdentifier(identifier)
    }
}
