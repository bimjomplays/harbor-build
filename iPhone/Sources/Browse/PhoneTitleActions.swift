import SwiftUI

/// What the phone does to a title from a long press or a hero button: save it to the watchlist, mark
/// a film watched, drop it from Continue Watching. It runs the same engine actions the TV's quick
/// panel and detail page run, and keeps a local answer for the moment between the tap and the
/// engine's marks catching up (under `--fixtures` that local answer is all there is).
@MainActor
final class PhoneTitleActions: ObservableObject {
    static let shared = PhoneTitleActions()

    @Published private(set) var savedOverride: [String: Bool] = [:]
    @Published private(set) var watchedOverride: [String: Bool] = [:]
    /// Ids whose Continue Watching card was removed here, hidden until the next load.
    @Published private(set) var dismissed: Set<String> = []
    private var busy: Set<String> = []

    private var authKey: String? {
        ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
    }

    func isSaved(_ meta: Meta, marks: CardMarks?) -> Bool {
        savedOverride[meta.id] ?? (marks?.bookmark != nil)
    }

    func isWatched(_ meta: Meta, marks: CardMarks?) -> Bool {
        watchedOverride[meta.id] ?? (marks?.watched != nil)
    }

    /// Mark watched is the engine's movie action (actions.setMovieWatched); a series is marked per episode on its page.
    func canMarkWatched(_ meta: Meta) -> Bool { meta.type == "movie" }

    /// Hero state for a title not yet in the marks table: Harbor's own watchlist (engine actions.heroState).
    func loadSaved(_ meta: Meta) async {
        guard !Fixtures.active, savedOverride[meta.id] == nil else { return }
        struct SavedState: Decodable { var watchlist: Bool? }
        let p = ProfilesStore.shared.active
        let noImdb: String? = nil
        guard let s: SavedState = try? await HarborEngine.shared.call("actions.heroState", [meta, noImdb, p?.id ?? "default", p?.linked ?? true]) else { return }
        guard savedOverride[meta.id] == nil else { return }
        savedOverride[meta.id] = s.watchlist == true
    }

    func toggleSaved(_ meta: Meta, current: Bool) async {
        guard busy.insert("s-\(meta.id)").inserted else { return }
        defer { busy.remove("s-\(meta.id)") }
        let on = !current
        savedOverride[meta.id] = on
        PhoneToaster.shared.show(on ? T("Added to Watchlist") : T("Removed from Watchlist"))
        guard !Fixtures.active else { return }
        let noImdb: String? = nil
        let key = authKey
        let done: Bool? = try? await HarborEngine.shared.call("actions.setWatchlist", [key, meta, noImdb, on])
        if done == nil {
            // The engine did not answer: put the old state back rather than claim a save that did not happen.
            savedOverride[meta.id] = current
            PhoneToaster.shared.show(T("Couldn't update your Watchlist"))
            return
        }
        await CardMarksStore.shared.remark()
    }

    func toggleWatched(_ meta: Meta, current: Bool) async {
        guard canMarkWatched(meta), busy.insert("w-\(meta.id)").inserted else { return }
        defer { busy.remove("w-\(meta.id)") }
        let next = !current
        watchedOverride[meta.id] = next
        PhoneToaster.shared.show(next ? T("Marked as watched") : T("Marked as unwatched"))
        guard !Fixtures.active else { return }
        let noImdb: String? = meta.id.hasPrefix("tt") ? meta.id : nil
        let done: Bool? = try? await HarborEngine.shared.call("actions.setMovieWatched", [meta, noImdb, next])
        if done == nil {
            watchedOverride[meta.id] = current
            PhoneToaster.shared.show(T("Couldn't update that title"))
            return
        }
        await CardMarksStore.shared.remark()
    }

    /// rooms.dismissContinueWatching, then the event the TV's Home also listens for.
    func removeFromContinue(_ id: String) async {
        dismissed.insert(id)
        guard !Fixtures.active else { return }
        let p = ProfilesStore.shared.active
        let key = authKey
        let ok = (try? await HarborEngine.shared.callJSON("rooms.dismissContinueWatching", [.string(p?.id ?? "default"), .bool(p?.linked ?? true), key.map { .string($0) } ?? .null, .string(id)]))?.bool ?? false
        if ok {
            HarborEngine.shared.emitEvent("harbor:cw-dismissed")
        } else {
            dismissed.remove(id)
            PhoneToaster.shared.show(T("This title isn't in Continue Watching."))
        }
    }

    /// A fresh load shows whatever the engine now says.
    func resetDismissed() { dismissed = [] }
}
