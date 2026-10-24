import Foundation
import Combine

// State and engine logic of the calendar's panels (RemindersManagerView, CalendarConfigRailView,
// CalendarPeopleSearchView), lifted out of the TV views. Each view draws and owns its focus ring; the
// model reaches it through `bindFocus`.

/// A focus ring the view owns, as a read / write pair.
private struct FocusRing {
    var read: () -> String? = { nil }
    var write: (String?) -> Void = { _ in }
}

/// components/reminders-manager.tsx: every reminder (newest first) with its summary.
@MainActor
final class RemindersManagerModel: ObservableObject {
    @Published var rows: [ReminderCenter.Row] = []
    @Published var loaded = false
    @Published var note: String?
    @Published var detail: Meta?
    /// The reminder whose show page is (or was last) open.
    private var lastOpened: String?
    private var ring = FocusRing()

    func bindFocus(read: @escaping () -> String?, write: @escaping (String?) -> Void) {
        ring = FocusRing(read: read, write: write)
    }

    private var focus: String? {
        get { ring.read() }
        set { ring.write(newValue) }
    }

    /// Once: the view's task runs again when a show's cover closes (onDismiss already
    /// re-reads the rows), and focus jumped from that show back to the first row.
    func loadOnce() async {
        guard !loaded else { return }
        rows = await ReminderCenter.shared.list()
        loaded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in focus = rows.first?.id ?? "close" }
    }

    func open(_ r: ReminderCenter.Row) {
        lastOpened = r.id
        detail = Meta(id: r.id, type: r.type == "movie" ? "movie" : "series", name: r.name, poster: r.poster)
    }

    /// The page just closed may have turned its reminder off (the clock on the show's page), and
    /// the re-read then drops the row tvOS hands the ring back to: it fell to
    /// whatever tvOS found. It goes to the row now in that place (the one before at the end), else
    /// to Close, as a remove here does.
    func rereadAfterPage() {
        let openedIndex: Int? = rows.firstIndex(where: { $0.id == lastOpened })
        let opened: String? = lastOpened
        Task {
            // An unreadable answer keeps the rows (list() gives [] then, which showed
            // "No reminders yet" over every reminder and sent the ring to Close), as remove does.
            let read: [ReminderCenter.Row]? = try? await HarborEngine.shared.call("calendar.reminders", [])
            guard let fresh = read else { return }
            rows = fresh
            guard let opened, !fresh.contains(where: { $0.id == opened }), detail == nil else { return }
            let target: String = fresh.isEmpty ? "close" : fresh[min(openedIndex ?? 0, fresh.count - 1)].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in if detail == nil { focus = target } }
        }
    }

    func remove(_ r: ReminderCenter.Row) async {
        let index = rows.firstIndex(of: r) ?? 0
        var next: [ReminderCenter.Row]? = await ReminderCenter.shared.remove(r.id)
        // An unreadable answer dropped the row and said "Reminder removed" whether or not
        // it went: the list is read again, and the rows stay as they are when that fails too.
        if next == nil {
            let fresh: [ReminderCenter.Row]? = try? await HarborEngine.shared.call("calendar.reminders", [])
            next = fresh
        }
        rows = next ?? rows
        let gone: Bool = !rows.contains(where: { $0.id == r.id })
        if gone { note = "Reminder removed" }
        focus = rows.isEmpty ? "close" : rows[min(index, rows.count - 1)].id
    }
}

/// calendar/config/config-rail.tsx for the Custom source: the engine's rail (media types, chip
/// groups, Trakt sources) and its toggles.
@MainActor
final class CalendarRailModel: ObservableObject {
    struct Chip: Decodable, Identifiable, Equatable { var key: String; var label: String; var selected: Bool; var id: String { key } }
    struct RailGroup: Decodable, Identifiable, Equatable { var id: String; var title: String; var count: Int; var summary: String; var chips: [Chip] }
    struct TraktRow: Decodable, Identifiable, Equatable { var key: String; var label: String; var sub: String; var on: Bool; var disabled: Bool; var id: String { key } }
    struct Rail: Decodable, Equatable {
        var activeCount: Int; var summary: String; var traktConnected: Bool; var tmdbKey: Bool
        var mediaTypes: [Chip]; var groups: [RailGroup]; var trakt: [TraktRow]
    }

    @Published var rail: Rail?
    @Published var open: Set<String> = ["genres"]
    @Published var addingPerson = false
    private var ring = FocusRing()

    func bindFocus(read: @escaping () -> String?, write: @escaping (String?) -> Void) {
        ring = FocusRing(read: read, write: write)
    }

    private var focus: String? {
        get { ring.read() }
        set { ring.write(newValue) }
    }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    func load() async {
        let p = profile
        rail = try? await HarborEngine.shared.call("calendar.customRail", [p.id, p.linked])
    }

    /// config-group.tsx: the header opens / closes the group.
    func toggleOpen(_ id: String) {
        if open.contains(id) { _ = open.remove(id) } else { _ = open.insert(id) }
    }

    /// A tracked person's chip removes the person (people-field onRemove), so the
    /// chip left from under the ring: the ring goes to the chip that takes its place (or the one
    /// before it at the end), else to the people search.
    func pressChip(_ c: Chip) {
        guard c.key.hasPrefix("person:") else {
            toggle(c.key)
            return
        }
        let before: [String] = rail?.groups.first(where: { $0.id == "people" })?.chips.map(\.key) ?? []
        let at: Int = before.firstIndex(of: c.key) ?? 0
        toggle(c.key) { next in
            let left: [String] = next.groups.first(where: { $0.id == "people" })?.chips.map(\.key) ?? []
            if left.isEmpty { return "addPerson" }
            return "chip:" + left[min(at, left.count - 1)]
        }
    }

    func toggle(_ key: String, refocus: ((Rail) -> String?)? = nil) {
        let p = profile
        Task {
            if let next: Rail = try? await HarborEngine.shared.call("calendar.customToggle", [p.id, p.linked, key]) {
                rail = next
                if let target = refocus?(next) { DispatchQueue.main.async { [self] in focus = target } }
            }
        }
    }
}

/// calendar/config/people-field.tsx on the TV: TMDB people after 220 ms, Select adds the person
/// (config-rail.tsx addPerson, role "any").
@MainActor
final class CalendarPeopleSearchModel: ObservableObject {
    struct Person: Decodable, Identifiable { var id: Int; var name: String; var profile: String?; var knownFor: String; var tracked: Bool }
    struct Found: Decodable { var needsKey: Bool; var people: [Person] }
    private struct Pick: Encodable { var id: Int; var name: String; var profile: String? }

    @Published var query = ""
    @Published var result: Found?
    @Published var busy = false

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    /// people-field.tsx: 220 ms after the last keystroke (the view runs this as `.task(id: query)`).
    func search() async {
        try? await Task.sleep(for: .milliseconds(220))
        if Task.isCancelled { return }
        busy = true
        let p = profile
        let found: Found? = try? await HarborEngine.shared.call("calendar.customPeopleSearch", [p.id, p.linked, query])
        if !Task.isCancelled { result = found }
        busy = false
    }

    /// Adds the person; `onAdded` gets the rail it answers with, then `done` closes the sheet.
    func add(_ person: Person, onAdded: @escaping (CalendarRailModel.Rail) -> Void, done: @escaping () -> Void) {
        guard !person.tracked else { return }
        let p = profile
        Task {
            if let next: CalendarRailModel.Rail = try? await HarborEngine.shared.call("calendar.customAddPerson", [p.id, p.linked, Pick(id: person.id, name: person.name, profile: person.profile)] as [any Encodable]) {
                onAdded(next)
            }
            done()
        }
    }
}
