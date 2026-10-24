import Foundation

/// The month grid and agenda as data. The engine's month build
/// (`calendar.month`, CalendarModel.Month) gives 42 grid cells with each day's releases; the phone
/// draws them twice: as a grid of weeks with dots, and as an agenda of the days that have releases.
enum PhoneCalendarGrouping {
    /// One agenda section: a day of the shown month with at least one release.
    struct Day: Identifiable, Equatable {
        let iso: String
        let day: Int
        let isToday: Bool
        /// The releases, earliest air time first (no time last), then by name.
        let entries: [CalendarModel.Entry]
        var id: String { iso }

        /// The releases keyed by day and place, unique across the whole agenda (an entry id can repeat).
        var rows: [Row] { entries.indices.map { Row(id: "\(iso)#\($0)", entry: entries[$0]) } }
    }

    struct Row: Identifiable {
        let id: String
        let entry: CalendarModel.Entry
    }

    /// The grid's rows: the cells in weeks of seven.
    static func weeks(_ cells: [CalendarModel.Cell]) -> [[CalendarModel.Cell]] {
        stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    /// The agenda: the shown month's days that have releases, in date order. The grid's leading and
    /// trailing days belong to the months beside it and are left to them.
    static func agenda(_ cells: [CalendarModel.Cell]) -> [Day] {
        cells.filter { $0.inMonth && !$0.items.isEmpty }
            .sorted { $0.iso < $1.iso }
            .map { Day(iso: $0.iso, day: $0.day, isToday: $0.isToday, entries: sortedByTime($0.items)) }
    }

    /// A day's releases by air time; a release with no time goes after the timed ones, and ties
    /// keep the engine's order.
    static func sortedByTime(_ entries: [CalendarModel.Entry]) -> [CalendarModel.Entry] {
        entries.enumerated().sorted { a, b in
            switch (a.element.releaseAtMs, b.element.releaseAtMs) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The dots under a grid day: one per release, at most three.
    static let maxDots = 3
    static func dots(_ cell: CalendarModel.Cell) -> [CalendarModel.Entry] {
        Array(cell.items.prefix(maxDots))
    }

    /// The agenda section a tapped day scrolls to: the day itself, else the next day with releases,
    /// else the last one before it; nil when the month has none.
    static func anchor(for iso: String, in days: [Day]) -> String? {
        if let next = days.first(where: { $0.iso >= iso }) { return next.iso }
        return days.last?.iso
    }

    /// The day picked when a month opens: today when it is in the month, else the first day with
    /// releases, else the 1st.
    static func initialDay(_ cells: [CalendarModel.Cell], todayISO: String) -> String? {
        let month = cells.filter(\.inMonth)
        if month.contains(where: { $0.iso == todayISO }) { return todayISO }
        return month.first(where: { !$0.items.isEmpty })?.iso ?? month.first?.iso
    }

    /// The month `by` months from `month` (0-based, as CalendarModel).
    static func step(year: Int, month: Int, by: Int) -> (year: Int, month: Int) {
        let total = year * 12 + month + by
        let y = total >= 0 ? total / 12 : (total - 11) / 12
        return (y, total - y * 12)
    }

    /// "2026-10-07".
    static func iso(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month + 1, day)
    }

    /// month-grid.tsx buildMonthCells with no releases: six weeks from the week holding the 1st,
    /// starting on Sunday or Monday. The grid draws these while a month is read, so a swipe lands
    /// on the new month's days at once (the TV shows its skeleton there).
    static func blankCells(year: Int, month: Int, weekStartsMonday: Bool, todayISO: String) -> [CalendarModel.Cell] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var c = DateComponents()
        c.year = year; c.month = month + 1; c.day = 1; c.hour = 12
        guard let first = calendar.date(from: c) else { return [] }
        let weekday = calendar.component(.weekday, from: first) // 1 = Sunday
        let lead = weekStartsMonday ? (weekday + 5) % 7 : weekday - 1
        return (0..<42).compactMap { i -> CalendarModel.Cell? in
            guard let date = calendar.date(byAdding: .day, value: i - lead, to: first) else { return nil }
            let p = calendar.dateComponents([.year, .month, .day], from: date)
            let y = p.year ?? year, m = (p.month ?? 1) - 1, d = p.day ?? 1
            let key = iso(year: y, month: m, day: d)
            return CalendarModel.Cell(iso: key, day: d, inMonth: y == year && m == month, isToday: key == todayISO, items: [])
        }
    }

    /// Today in the viewer's time zone, as the engine's todayLocalISO.
    static func todayISO(_ now: Date = Date()) -> String {
        let p = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return iso(year: p.year ?? 2026, month: (p.month ?? 1) - 1, day: p.day ?? 1)
    }

    /// "S2E4" for an episode, nil for a film or a release with no episode.
    static func episodeTag(_ entry: CalendarModel.Entry) -> String? {
        guard let season = entry.season, let episode = entry.episode else { return nil }
        return "S\(season)E\(episode)"
    }
}
