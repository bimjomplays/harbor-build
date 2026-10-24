import Foundation

/// The Calendar under `--fixtures` on the phone: the engine is not started there, so the month and
/// the reminders come from here instead of `calendar.month` / `calendar.reminders`. Every month
/// shown has releases on the 3rd (one), the 12th (two) and the 21st (three); the reminders list
/// holds three shows until one is removed (in memory, for this launch). `--fixtures calfail` keeps
/// the shared model's failing read, and `--fixtures live` the real engine.
@MainActor
enum PhoneCalendarFixtures {
    static var active: Bool { Fixtures.active && !Fixtures.liveRooms && !FixtureBrowseSource.failCalendar }

    /// The days of a fixture month that have releases.
    static let releaseDays = [3, 12, 21]

    /// FixtureBrowseSource's ids and names, so a release opens the same fixture title page.
    private static let shows: [(id: String, type: String, name: String, anime: Bool)] = [
        ("s-3", "series", "Severance", false),
        ("s-2", "series", "The Bear", false),
        ("m-0", "movie", "Dune: Part Two", false),
        ("s-5", "series", "Shōgun", true),
        ("s-11", "series", "Ripley", false),
        ("m-6", "movie", "Past Lives", false),
    ]

    static func month(year: Int, month: Int) -> CalendarModel.Month {
        let today = PhoneCalendarGrouping.todayISO()
        var cells = PhoneCalendarGrouping.blankCells(year: year, month: month, weekStartsMonday: false, todayISO: today)
        var next = 0
        for (n, day) in releaseDays.enumerated() {
            guard let i = cells.firstIndex(where: { $0.inMonth && $0.day == day }) else { continue }
            cells[i].items = (0...n).map { k -> CalendarModel.Entry in
                defer { next += 1 }
                return entry(shows[next % shows.count], iso: cells[i].iso, hour: 18 + k, episode: day / 3)
            }
        }
        let total = cells.reduce(0) { $0 + $1.items.count }
        return CalendarModel.Month(
            year: year, month: month, monthLabel: label(year: year, month: month), todayISO: today,
            source: "library", sources: [], traktConnected: false, simklConnected: false, signedIn: true,
            weekStartsMonday: false, posterSize: "default", weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map { T($0) },
            animeDubToggle: false, animeDub: false, hideTypeTag: false, filters: [], filter: "all",
            watchlistToggle: false, watchlistOnly: false, custom: nil, status: total > 0 ? "ready" : "empty", error: nil,
            emptyHeading: "", emptyBody: "", total: total, cells: cells)
    }

    private static func entry(_ show: (id: String, type: String, name: String, anime: Bool), iso: String, hour: Int, episode: Int) -> CalendarModel.Entry {
        let film = show.type == "movie"
        let at = date(iso, hour: hour)
        return CalendarModel.Entry(
            id: film ? show.id : "\(show.id):1:\(episode)", name: show.name, type: film ? "movie" : "tv", poster: nil,
            releaseDate: iso, releaseTime: at.map { $0.formatted(date: .omitted, time: .shortened) },
            releaseAtMs: at.map { $0.timeIntervalSince1970 * 1000 }, upcoming: nil, isAnime: show.anime,
            overview: "A placeholder synopsis for \(show.name).", voteAverage: 7.5,
            tag: show.anime ? T("Anime") : film ? T("Movie") : T("TV"), dateLong: dateLong(iso),
            meta: Meta(id: show.id, type: show.type, name: show.name, poster: nil),
            season: film ? nil : 1, episode: film ? nil : episode)
    }

    private static func date(_ iso: String, hour: Int) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = hour
        return Calendar.current.date(from: c)
    }

    private static func dateLong(_ iso: String) -> String? {
        date(iso, hour: 12)?.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(L10n.locale))
    }

    private static func label(year: Int, month: Int) -> String {
        var c = DateComponents()
        c.year = year; c.month = month + 1; c.day = 1
        return Calendar.current.date(from: c)?.formatted(.dateTime.month(.wide).year().locale(L10n.locale)) ?? ""
    }

    // MARK: Reminders

    private static var reminderRows: [ReminderCenter.Row] = [
        .init(id: "s-3", name: "Severance", poster: nil, type: "series", summary: "Episodes + Seasons · Chime", unseen: true),
        .init(id: "s-2", name: "The Bear", poster: nil, type: "series", summary: "Episodes + Seasons · Chime", unseen: false),
        .init(id: "s-5", name: "Shōgun", poster: nil, type: "series", summary: "Episodes · Chime", unseen: false),
    ]

    static var reminders: [ReminderCenter.Row] { reminderRows }

    static func removeReminder(_ id: String) -> [ReminderCenter.Row] {
        reminderRows.removeAll { $0.id == id }
        return reminderRows
    }
}
