import Foundation

/// The Trackers screen under `--fixtures` (no engine): Trakt's session has expired (reconnect),
/// Simkl and AniList are connected with lists, MyAnimeList and Letterboxd are signed out. Simkl was
/// synced five minutes before launch, AniList never. A sign-out or a sync holds for this launch only;
/// `--fixtures live` reads the real engine.
@MainActor
enum PhoneTrackersFixtures {
    static var active: Bool { Fixtures.active && !Fixtures.liveRooms }

    static let simklUser = "harbor-fan"
    static let anilistUser = "HarborFan"

    static let states: [PhoneTracker: PhoneTrackerState] = [
        .trakt: .reconnect(username: "harbor-fan"),
        .simkl: .connected(username: simklUser),
        .anilist: .connected(username: anilistUser),
        .mal: .signedOut,
        .letterboxd: .signedOut,
    ]

    static let lists: [PhoneTracker: PhoneTrackersModel.Lists] = [
        .trakt: PhoneTrackersModel.Lists(total: 46, groups: [
            .init(id: "watchlist", label: "Watchlist", count: 6), .init(id: "history", label: "History", count: 40),
        ]),
        .simkl: PhoneTrackersModel.Lists(total: 33, groups: [
            .init(id: "watching", label: "Watching", count: 3), .init(id: "plantowatch", label: "Plan to Watch", count: 8),
            .init(id: "completed", label: "Completed", count: 20), .init(id: "hold", label: "On Hold", count: 1),
            .init(id: "dropped", label: "Dropped", count: 1),
        ]),
        .anilist: PhoneTrackersModel.Lists(total: 50, groups: [
            .init(id: "watching", label: "Watching", count: 4), .init(id: "planning", label: "Plan to Watch", count: 12),
            .init(id: "completed", label: "Completed", count: 31), .init(id: "paused", label: "On Hold", count: 2),
            .init(id: "dropped", label: "Dropped", count: 1),
        ]),
    ]

    /// A sync log of its own, emptied at launch, so every fixture run starts from the same times.
    static func syncLog() -> PhoneTrackerSyncLog {
        let name = "phone.trackers.fixtures"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let log = PhoneTrackerSyncLog(defaults: defaults)
        log.record(.simkl, at: Date().addingTimeInterval(-5 * 60))
        return log
    }
}
