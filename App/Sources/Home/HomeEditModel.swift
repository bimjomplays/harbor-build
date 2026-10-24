import SwiftUI

/// Edit Home's working copy of the active profile's HomeLayout. Every change is saved
/// at once (HomeLayoutStore, per profile), so Menu anywhere keeps what was done; Home re-reads when
/// the editor closes. The rows and the hero come from the same sources the iPhone offers
/// (HomeSourceRegistry), read for the pickers through HomeLayoutBrowseSource.allSources.
///
/// On the Apple TV, Home's own Continue Watching is the lead row above the rail (RoomView draws it
/// there wherever the layout puts it), so it is kept first here: it can be removed and added back,
/// never moved below another row.
@MainActor
final class HomeEditModel: ObservableObject {
    /// One row of the layout as the editor lists it.
    struct Line: Identifiable, Equatable {
        /// The spec's id.
        var id: String
        /// Its source's identity: the editor's accessibility ids key off it (UI tests).
        var identity: String
        var title: String
        var subtitle: String
        var systemImage: String
        /// Home's Continue Watching: always the lead row.
        var pinned: Bool
        /// A whole page's rows that can be split into rows of their own.
        var canSplit: Bool
        /// Nothing serves it right now (Home skips it): drawn dimmed with why.
        var unavailable: Bool
    }

    /// The picker's sources, by group, in HomeSourceEntry.Group order.
    struct SourceGroup: Identifiable {
        var group: HomeSourceEntry.Group
        var entries: [HomeSourceEntry]
        var id: String { group.rawValue }
    }

    let source: HomeLayoutBrowseSource
    let profileId: String
    @Published private(set) var layout: HomeLayout
    /// Every source on offer; nil until read.
    @Published private(set) var snapshot: HomeSourceSnapshot?
    @Published private(set) var loadingSources = false

    init(source: HomeLayoutBrowseSource) {
        self.source = source
        profileId = source.profileId
        var layout = source.store.layout(for: source.profileId)
        Self.pinLead(&layout)
        self.layout = layout
    }

    var profileName: String { ProfilesStore.shared.active?.name ?? "" }

    func loadSources() async {
        guard snapshot == nil, !loadingSources else { return }
        loadingSources = true
        snapshot = await source.allSources()
        loadingSources = false
    }

    // MARK: Rows

    var lines: [Line] { layout.rows.map(line(for:)) }

    static func isPinned(_ source: HomeRowSource) -> Bool { source == .continueWatching(.home) }

    /// What a row's name and note are worked out from before the sources are read: the entries that
    /// need no read (Continue Watching, whole pages, the tracker lists) are already right.
    private var known: HomeSourceSnapshot { snapshot ?? HomeSourceSnapshot() }

    private func line(for spec: HomeRowSpec) -> Line {
        let entry: HomeSourceEntry? = HomeSourceRegistry.entry(for: spec.source, in: known)
        let own: String? = spec.title.flatMap { $0.isEmpty ? nil : $0 }
        let title: String = own ?? entry?.title ?? spec.savedTitle ?? T("Unknown source")
        let pinned = Self.isPinned(spec.source)
        var subtitle: String
        if pinned {
            subtitle = T("Always the first row on Apple TV")
        } else if let entry, let note = entry.subtitle {
            subtitle = note
        } else if let group = entry?.group ?? spec.source.room.map(HomeSourceRegistry.group(for:)) {
            subtitle = group.title
        } else {
            subtitle = spec.source.isKnown ? T("Addons") : T("Made by a newer version of Harbor")
        }
        var unavailable = false
        if snapshot != nil {
            if entry == nil || entry?.availability == .unavailable {
                unavailable = true
                subtitle = T("Not available right now")
            } else if entry?.availability == .needsSignIn {
                unavailable = true
                subtitle = T("Sign in under Settings to show it")
            }
        }
        var canSplit = false
        if case .engineRoom(let room) = spec.source, let rows = snapshot?.pages[room]?.rows, !rows.isEmpty { canSplit = true }
        return Line(id: spec.id, identity: spec.source.identity, title: title, subtitle: subtitle,
                    systemImage: entry?.systemImage ?? Self.icon(for: spec.source), pinned: pinned,
                    canSplit: canSplit, unavailable: unavailable)
    }

    private static func icon(for source: HomeRowSource) -> String {
        switch source {
        case .engineRoom(let room): return room.room.icon
        case .engineRow: return "rectangle.stack"
        case .continueWatching: return "play.circle"
        case .anilistList, .malList: return "list.star"
        case .addonCatalog: return "puzzlepiece.extension"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    /// Up (−1) or down (+1) one place; never onto or past the pinned lead.
    func canMove(_ id: String, by delta: Int) -> Bool {
        guard let i = layout.index(of: id), !Self.isPinned(layout.rows[i].source) else { return false }
        let to = i + delta
        guard layout.rows.indices.contains(to) else { return false }
        return !Self.isPinned(layout.rows[to].source)
    }

    @discardableResult
    func move(_ id: String, by delta: Int) -> Bool {
        guard canMove(id, by: delta) else { return false }
        layout.move(id: id, by: delta)
        save()
        return true
    }

    /// Removes a row; answers the id of the row now in its place (the one above at the end), for
    /// the ring.
    func remove(_ id: String) -> String? {
        guard let i = layout.index(of: id) else { return nil }
        layout.remove(id: id)
        save()
        guard !layout.rows.isEmpty else { return nil }
        return layout.rows[min(i, layout.rows.count - 1)].id
    }

    /// A whole page's rows one by one, in the order the page built them.
    func split(_ id: String) -> String? {
        guard let i = layout.index(of: id), case .engineRoom(let room) = layout.rows[i].source,
              let rows = snapshot?.pages[room]?.rows, !rows.isEmpty else { return nil }
        layout.expandRoom(id: id, rows: rows)
        save()
        return layout.rows.indices.contains(i) ? layout.rows[i].id : nil
    }

    // MARK: Adding

    func onHome(_ entry: HomeSourceEntry) -> Bool { layout.contains(entry.source) }

    /// The sources a row (or the hero) can come from, grouped; the unavailable ones are left out.
    var groups: [SourceGroup] {
        guard let snapshot else { return [] }
        let entries = HomeSourceRegistry.entries(in: snapshot).filter { $0.availability != .unavailable }
        var seen = Set<String>()
        return HomeSourceEntry.Group.allCases.compactMap { group in
            let mine = entries.filter { $0.group == group && seen.insert($0.id).inserted }
            return mine.isEmpty ? nil : SourceGroup(group: group, entries: mine)
        }
    }

    /// Adds a source's row (Home's Continue Watching back at the top, anything else at the end) and
    /// answers its id.
    @discardableResult
    func add(_ entry: HomeSourceEntry) -> String? {
        guard entry.availability == .available, !onHome(entry) else { return nil }
        let id = layout.insert(entry.source, savedTitle: entry.title, at: Self.isPinned(entry.source) ? 0 : nil)
        save()
        return id
    }

    // MARK: Hero

    var heroTitle: String {
        switch layout.hero {
        case .auto: return T("Automatic")
        case .off: return T("Off")
        case .source(let s):
            if let entry = HomeSourceRegistry.entry(for: s, in: known) { return entry.title }
            return snapshot == nil ? T("Loading…") : T("Not available right now")
        }
    }

    var heroNote: String {
        switch layout.hero {
        case .auto: return T("The first row's titles take turns at the top of Home.")
        case .off: return T("The top of Home shows the title you're on.")
        case .source: return T("This source's titles take turns at the top of Home.")
        }
    }

    func setHero(_ hero: HomeHeroSource) {
        guard layout.hero != hero else { return }
        layout.hero = hero
        save()
    }

    // MARK: Saving

    var isDefault: Bool { layout.isDefault }

    func reset() {
        source.store.reset(for: profileId)
        layout = .standard
    }

    private func save() {
        source.store.save(layout, for: profileId)
    }

    /// Home's Continue Watching first (a layout saved before the rule, or edited elsewhere).
    private static func pinLead(_ layout: inout HomeLayout) {
        guard let i = layout.rows.firstIndex(where: { isPinned($0.source) }), i > 0 else { return }
        let spec = layout.rows.remove(at: i)
        layout.rows.insert(spec, at: 0)
    }
}
