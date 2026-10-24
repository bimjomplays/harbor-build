import SwiftUI

/// queue/bp-queue.tsx: the Discovery Queue deck. One pick at a time on its own backdrop, Left/Right
/// step through the deck, the rail offers Play now / Save / Details / Skip / Not interested.
@MainActor
final class QueueDeckModel: ObservableObject {
    struct Entry: Decodable, Identifiable { var meta: Meta; var tag: String; var id: String { meta.id } }
    struct Deck: Decodable { var status: String; var entries: [Entry] }

    @Published private(set) var status = "loading"
    @Published private(set) var entries: [Entry] = []
    @Published var index = 0
    @Published private(set) var saved: Set<String> = []
    private var extending = false

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }

    private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true, p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    /// The view's `.task` runs again whenever a Details / Play now cover closes; the deck
    /// opened again then, back on its first card with a fresh fetch.
    private var opened = false

    /// True for the call that opened the deck (the view seeds focus only then).
    @discardableResult
    func open() async -> Bool {
        guard !opened else { return false }
        opened = true
        let p = profile
        if let d: Deck = try? await HarborEngine.shared.call("discoverRoom.queueOpen", [p.id, p.linked]) {
            entries = d.entries; status = d.status
        } else { status = "unreachable" }
        index = 0
        await CardMarksStore.shared.refresh(entries.map(\.meta))
        return true
    }

    func step(_ delta: Int) {
        let next = index + delta
        guard entries.indices.contains(next) else { return }
        index = next
        // use-bp-queue LOW_WATER_MARK: fetch another page as the end nears.
        if entries.count - index - 1 <= 6 { Task { await extend() } }
    }

    private func extend() async {
        guard !extending else { return }
        extending = true; defer { extending = false }
        let p = profile
        let more: [Entry] = (try? await HarborEngine.shared.call("discoverRoom.queueExtend", [p.id, p.linked])) ?? []
        let have = Set(entries.map(\.id))
        entries += more.filter { !have.contains($0.id) }
    }

    /// Drop the pick (the current one unless named) and land on the next one (or the previous when it was last).
    private func remove(_ fn: String, id: String? = nil) async {
        guard let target = id ?? current?.id else { return }
        _ = try? await HarborEngine.shared.callJSON("discoverRoom.\(fn)", [.string(target)])
        // Left / Right may have moved the deck while the engine answered: drop that pick by id.
        guard let at = entries.firstIndex(where: { $0.id == target }) else { return }
        entries.remove(at: at)
        if at < index { index -= 1 }
        if index >= entries.count { index = max(0, entries.count - 1) }
        if entries.isEmpty { status = "empty" }
        if entries.count - index - 1 <= 6 { await extend() }
    }
    func snooze() async { await remove("queueSnooze") }
    /// bp-queue.tsx: Not interested runs only from the "Hide this permanently?" confirm, on the
    /// title it named.
    func block(_ id: String) async { await remove("queueBlock", id: id) }

    private struct WatchlistState: Decodable { var watchlist: Bool? }
    private var saving = false

    /// bp-queue-rail useInWatchlist(meta.id): Save / Saved follows Harbor's watchlist (and the synced
    /// Stremio/Trakt/Simkl aggregate) for the card on screen.
    func readSaved() async {
        guard let c = current else { return }
        let p = profile
        let noImdb: String? = nil
        guard let s: WatchlistState = try? await HarborEngine.shared.call("actions.heroState", [c.meta, noImdb, p.id, p.linked]) else { return }
        if s.watchlist == true { saved.insert(c.id) } else { saved.remove(c.id) }
    }

    /// bp-queue-rail Save: toggleWatchlist({ id, type, name, poster }) (engine actions.setWatchlist).
    /// It wrote a Stremio library bookmark, so it was missing without a Stremio
    /// account, could not be undone, never showed a title already saved elsewhere as Saved, and
    /// never reached Trakt, Simkl or the Library room's watchlist.
    func toggleSave() async {
        guard let c = current, !saving else { return }
        saving = true
        defer { saving = false }
        let on = !saved.contains(c.id)
        let noImdb: String? = nil
        let _: Bool? = try? await HarborEngine.shared.call("actions.setWatchlist", [profile.authKey, c.meta, noImdb, on])
        if on { saved.insert(c.id) } else { saved.remove(c.id) }
        await CardMarksStore.shared.remark()
    }
}
