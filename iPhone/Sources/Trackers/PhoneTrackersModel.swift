import SwiftUI

/// The Trackers screen's state: each tracker's sign-in, its lists' sizes and when they were last
/// fetched. Status, sign-out and the list read go through what the TV uses (the engine's
/// `<service>.status`, TraktModel / PasteTrackerModel / LetterboxdModel's disconnect, the Library's
/// `libraryRoom.feed`), so a sign-out here also clears what the TV's Settings would. Under
/// `--fixtures` (no engine) PhoneTrackersFixtures stands in and nothing leaves the app.
@MainActor
final class PhoneTrackersModel: ObservableObject {
    struct ListGroup: Identifiable, Equatable { var id: String; var label: String; var count: Int }
    /// One tracker's lists as its Library tab reads them: every entry, and each status group's size.
    struct Lists: Equatable { var total: Int; var groups: [ListGroup] }

    @Published private(set) var states: [PhoneTracker: PhoneTrackerState] = [:]
    @Published private(set) var lists: [PhoneTracker: Lists] = [:]
    @Published private(set) var syncing: Set<PhoneTracker> = []
    @Published private(set) var syncFailed: Set<PhoneTracker> = []
    @Published private(set) var loaded = false
    /// Bumped when a sync time changes, so "Synced …" is drawn again.
    @Published private(set) var syncRevision = 0

    let fixtures: Bool
    private let log: PhoneTrackerSyncLog

    /// `fixtures` nil: PhoneTrackersFixtures.active (read here, on the main actor, not as a default argument).
    init(fixtures: Bool? = nil, log: PhoneTrackerSyncLog? = nil) {
        let fixtures = fixtures ?? PhoneTrackersFixtures.active
        self.fixtures = fixtures
        self.log = log ?? (fixtures ? PhoneTrackersFixtures.syncLog() : PhoneTrackerSyncLog())
    }

    private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true, p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    func state(_ tracker: PhoneTracker) -> PhoneTrackerState { states[tracker] ?? .signedOut }

    func lastSynced(_ tracker: PhoneTracker) -> Date? { log.date(for: tracker) }

    // MARK: Status

    func refresh() async {
        if fixtures {
            if !loaded {
                states = PhoneTrackersFixtures.states
                lists = PhoneTrackersFixtures.lists
            }
            loaded = true
            return
        }
        for tracker in PhoneTracker.allCases {
            if let s = await read(tracker) { states[tracker] = s }
        }
        loaded = true
    }

    func refresh(_ tracker: PhoneTracker) async {
        guard !fixtures else { return }
        if let s = await read(tracker) { states[tracker] = s }
    }

    /// nil when the engine could not answer: the last known state stays on screen.
    private func read(_ tracker: PhoneTracker) async -> PhoneTrackerState? {
        if tracker == .letterboxd {
            let p = profile
            guard let s: LetterboxdModel.Status = try? await HarborEngine.shared.call("letterboxd.status", [p.id, p.linked]) else { return nil }
            return s.active ? .connected(username: s.username) : .signedOut
        }
        guard let s: TraktModel.Status = try? await HarborEngine.shared.call("\(tracker.service).status", []) else { return nil }
        return PhoneTrackerState(authenticated: s.authenticated, username: s.username, reconnect: s.reconnect)
    }

    // MARK: Sign out

    /// The TV panels' confirmed Disconnect (Simkl's also resets the profile's Simkl settings,
    /// Letterboxd's turns the integration off). `disconnect`: the tracker page's own shared model's,
    /// so that model's sign-in note is cleared with it (the caller leaves the engine alone on fixtures);
    /// nil, a fresh model's.
    func signOut(_ tracker: PhoneTracker, disconnect: (() async -> Void)? = nil) async {
        if let disconnect {
            await disconnect()
        } else if !fixtures {
            switch tracker.flow {
            case .deviceCode: await TraktModel(service: tracker.service, label: tracker.label).disconnect()
            case .authorizeCode: await PasteTrackerModel(service: tracker.service, label: tracker.label).disconnect()
            case .username: await LetterboxdModel().disable()
            }
        }
        states[tracker] = .signedOut
        lists[tracker] = nil
        syncFailed.remove(tracker)
        log.clear(tracker)
        syncRevision &+= 1
        await refresh(tracker)
    }

    /// A sign-in finished on the tracker's page: its state is read again and its lists fetched.
    func signedIn(_ tracker: PhoneTracker) async {
        await refresh(tracker)
        if state(tracker).hasSession { await sync(tracker) }
    }

    // MARK: Lists

    /// The tracker's Library tab, forced past its caches when `force` (Sync now). Whether it worked.
    @discardableResult
    func sync(_ tracker: PhoneTracker, force: Bool = true) async -> Bool {
        guard state(tracker).hasSession, !syncing.contains(tracker) else { return false }
        syncing.insert(tracker)
        defer { syncing.remove(tracker) }
        if fixtures {
            try? await Task.sleep(for: .milliseconds(400))
            log.record(tracker)
            syncFailed.remove(tracker)
            syncRevision &+= 1
            return true
        }
        let p = profile
        let input: AnyJSON = .object([
            "tab": .string(tracker.service), "profileId": .string(p.id), "linked": .bool(p.linked),
            "authKey": p.authKey.map { .string($0) } ?? .null, "flat": .bool(true), "limit": .number(1), "force": .bool(force),
        ])
        guard let feed: LibraryModel.Feed = try? await HarborEngine.shared.call("libraryRoom.feed", [input]) else {
            syncFailed.insert(tracker)
            return false
        }
        let ok = feed.status != "error"
        if ok || lists[tracker] == nil {
            lists[tracker] = Lists(total: feed.entries ?? feed.counts.all,
                                   groups: feed.groups.map { ListGroup(id: $0.id, label: $0.label, count: $0.count ?? 0) })
        }
        if ok {
            syncFailed.remove(tracker)
            if force { log.record(tracker) }
        } else {
            syncFailed.insert(tracker)
        }
        syncRevision &+= 1
        return ok
    }

    /// The page's first read: what the caches hold, fetched only when they hold nothing.
    func loadLists(_ tracker: PhoneTracker) async {
        guard lists[tracker] == nil, !fixtures else { return }
        await sync(tracker, force: false)
    }
}

/// Simkl's switches on the TV: Scrobbling (settings.simklScrobbleEnabled, TraktPanel) and the Home
/// rails (HomeRowsPanel through `rooms.homeSimklRail`; lib/simkl/home-rails.ts gates Up Next and
/// Trending behind the rails as a whole). Under fixtures they are kept for the launch only.
@MainActor
final class PhoneSimklOptions: ObservableObject {
    private struct RowsState: Decodable {
        struct Simkl: Decodable { var connected: Bool; var home: Bool; var upNext: Bool; var trending: Bool }
        var simkl: Simkl
    }

    @Published private(set) var scrobble = true
    @Published private(set) var home = false
    @Published private(set) var upNext = false
    @Published private(set) var trending = false
    let fixtures: Bool

    init(fixtures: Bool? = nil) { self.fixtures = fixtures ?? PhoneTrackersFixtures.active }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    func load() async {
        guard !fixtures else { return }
        scrobble = SettingsBridge.shared.slice.simklScrobbleEnabled ?? true
        let p = profile
        if let s: RowsState = try? await HarborEngine.shared.call("rooms.homeRowsState", [p.id, p.linked]) { apply(s) }
    }

    func setScrobble(_ on: Bool) async {
        scrobble = on
        guard !fixtures else { return }
        do {
            try await SettingsBridge.shared.patch(["simklScrobbleEnabled": .bool(on)])
        } catch {
            scrobble = SettingsBridge.shared.slice.simklScrobbleEnabled ?? true
        }
    }

    /// `which`: "home", "upNext" or "trending" (engine homeExtras setSimklRail).
    func setRail(_ which: String, _ on: Bool) async {
        switch which {
        case "home": home = on
        case "upNext": upNext = on
        default: trending = on
        }
        guard !fixtures else { return }
        let p = profile
        let out = try? await HarborEngine.shared.callJSON("rooms.homeSimklRail", [.string(p.id), .bool(p.linked), .string(which), .bool(on)])
        if let s = try? out?.decode(RowsState.self) { apply(s) } else { await load() }
    }

    private func apply(_ s: RowsState) {
        home = s.simkl.home
        upNext = s.simkl.upNext
        trending = s.simkl.trending
    }
}
