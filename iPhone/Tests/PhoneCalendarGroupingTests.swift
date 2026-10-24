import XCTest
@testable import HarborPhone

/// The Calendar's month grid and agenda as data (PhoneCalendarGrouping): weeks, the agenda's days
/// and their order, the blank grid drawn while a month is read, month steps and the tapped-day anchor.
final class PhoneCalendarGroupingTests: XCTestCase {
    private func entry(_ id: String, at ms: Double? = nil, season: Int? = nil, episode: Int? = nil, type: String = "tv") -> CalendarModel.Entry {
        CalendarModel.Entry(
            id: id, name: id, type: type, poster: nil, releaseDate: "", releaseTime: nil, releaseAtMs: ms, upcoming: nil,
            isAnime: false, overview: nil, voteAverage: nil, tag: "TV", dateLong: nil,
            meta: Meta(id: id, type: type == "movie" ? "movie" : "series", name: id, poster: nil), season: season, episode: episode)
    }

    private func cell(_ iso: String, inMonth: Bool = true, today: Bool = false, _ items: [CalendarModel.Entry] = []) -> CalendarModel.Cell {
        let day = Int(iso.split(separator: "-").last ?? "") ?? 0
        return CalendarModel.Cell(iso: iso, day: day, inMonth: inMonth, isToday: today, items: items)
    }

    // MARK: Grid

    func testWeeksAreRowsOfSeven() {
        let cells = PhoneCalendarGrouping.blankCells(year: 2026, month: 9, weekStartsMonday: false, todayISO: "")
        let weeks = PhoneCalendarGrouping.weeks(cells)
        XCTAssertEqual(weeks.count, 6)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(weeks.flatMap { $0 }.map(\.iso), cells.map(\.iso))
    }

    func testBlankMonthStartsOnSunday() {
        // 1 October 2026 is a Thursday: Sunday 27 September leads the grid.
        let cells = PhoneCalendarGrouping.blankCells(year: 2026, month: 9, weekStartsMonday: false, todayISO: "2026-10-18")
        XCTAssertEqual(cells.count, 42)
        XCTAssertEqual(cells.first?.iso, "2026-09-27")
        XCTAssertEqual(cells[4].iso, "2026-10-01")
        XCTAssertFalse(cells[3].inMonth)
        XCTAssertTrue(cells[4].inMonth)
        XCTAssertEqual(cells.filter(\.inMonth).count, 31)
        XCTAssertEqual(cells.filter(\.isToday).map(\.iso), ["2026-10-18"])
        XCTAssertEqual(cells.last?.iso, "2026-11-07")
        XCTAssertTrue(cells.allSatisfy { $0.items.isEmpty })
    }

    func testBlankMonthStartsOnMonday() {
        let cells = PhoneCalendarGrouping.blankCells(year: 2026, month: 9, weekStartsMonday: true, todayISO: "")
        XCTAssertEqual(cells.first?.iso, "2026-09-28")
        XCTAssertEqual(cells[3].iso, "2026-10-01")
        // A month whose 1st is a Monday (June 2026) starts the grid on it; a Sunday 1st (February 2026) ends the first week.
        XCTAssertEqual(PhoneCalendarGrouping.blankCells(year: 2026, month: 5, weekStartsMonday: true, todayISO: "").first?.iso, "2026-06-01")
        XCTAssertEqual(PhoneCalendarGrouping.blankCells(year: 2026, month: 1, weekStartsMonday: true, todayISO: "")[6].iso, "2026-02-01")
        XCTAssertEqual(PhoneCalendarGrouping.blankCells(year: 2026, month: 1, weekStartsMonday: false, todayISO: "").first?.iso, "2026-02-01")
    }

    func testDotsStopAtThree() {
        let busy = cell("2026-10-05", (0..<5).map { entry("e\($0)") })
        XCTAssertEqual(PhoneCalendarGrouping.dots(busy).map(\.id), ["e0", "e1", "e2"])
        XCTAssertEqual(PhoneCalendarGrouping.dots(cell("2026-10-06")).count, 0)
        XCTAssertEqual(PhoneCalendarGrouping.dots(cell("2026-10-07", [entry("a")])).count, 1)
    }

    // MARK: Agenda

    func testAgendaKeepsTheMonthsDaysWithReleasesInOrder() {
        let cells = [
            cell("2026-09-30", inMonth: false, [entry("before")]),
            cell("2026-10-12", [entry("b")]),
            cell("2026-10-03", today: true, [entry("a")]),
            cell("2026-10-04"),
            cell("2026-11-01", inMonth: false, [entry("after")]),
        ]
        let days = PhoneCalendarGrouping.agenda(cells)
        XCTAssertEqual(days.map(\.iso), ["2026-10-03", "2026-10-12"])
        XCTAssertEqual(days.map(\.day), [3, 12])
        XCTAssertEqual(days.map(\.isToday), [true, false])
        XCTAssertEqual(days.map(\.id), days.map(\.iso))
    }

    func testADaysReleasesGoByAirTimeUntimedLast() {
        let day = cell("2026-10-12", [entry("late", at: 3_000), entry("untimed"), entry("early", at: 1_000),
                                      entry("tieA", at: 2_000), entry("tieB", at: 2_000), entry("untimed2")])
        let entries = PhoneCalendarGrouping.agenda([day]).first?.entries.map(\.id)
        XCTAssertEqual(entries, ["early", "tieA", "tieB", "late", "untimed", "untimed2"])
    }

    func testAgendaRowKeysAreUniqueAcrossDays() {
        // Every section of the agenda's one LazyVStack has its rows; keys repeated across days drew blank rows.
        let days = PhoneCalendarGrouping.agenda([
            cell("2026-10-03", [entry("a")]), cell("2026-10-12", [entry("b"), entry("c")]),
            cell("2026-10-21", [entry("d"), entry("d"), entry("e")]),
        ])
        let keys = days.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(keys.count, 6)
        XCTAssertEqual(Set(keys).count, 6)
        XCTAssertEqual(days[2].rows.map(\.entry.id), ["d", "d", "e"])
    }

    func testAgendaOfAnEmptyMonthIsEmpty() {
        let cells = PhoneCalendarGrouping.blankCells(year: 2026, month: 9, weekStartsMonday: false, todayISO: "")
        XCTAssertTrue(PhoneCalendarGrouping.agenda(cells).isEmpty)
    }

    // MARK: Tapping a day

    func testATappedDayScrollsToItselfOrTheNextDayWithReleases() {
        let days = PhoneCalendarGrouping.agenda([
            cell("2026-10-03", [entry("a")]), cell("2026-10-12", [entry("b")]), cell("2026-10-21", [entry("c")]),
        ])
        XCTAssertEqual(PhoneCalendarGrouping.anchor(for: "2026-10-12", in: days), "2026-10-12")
        XCTAssertEqual(PhoneCalendarGrouping.anchor(for: "2026-10-01", in: days), "2026-10-03")
        XCTAssertEqual(PhoneCalendarGrouping.anchor(for: "2026-10-13", in: days), "2026-10-21")
        // Past the last release the agenda stays on it.
        XCTAssertEqual(PhoneCalendarGrouping.anchor(for: "2026-10-30", in: days), "2026-10-21")
        XCTAssertNil(PhoneCalendarGrouping.anchor(for: "2026-10-30", in: []))
    }

    func testAMonthOpensOnTodayElseItsFirstRelease() {
        let cells = [
            cell("2026-09-30", inMonth: false, [entry("x")]),
            cell("2026-10-01"), cell("2026-10-05", [entry("a")]), cell("2026-10-18"),
        ]
        XCTAssertEqual(PhoneCalendarGrouping.initialDay(cells, todayISO: "2026-10-18"), "2026-10-18")
        XCTAssertEqual(PhoneCalendarGrouping.initialDay(cells, todayISO: "2026-11-02"), "2026-10-05")
        // Today in a leading day of another month does not count.
        XCTAssertEqual(PhoneCalendarGrouping.initialDay(cells, todayISO: "2026-09-30"), "2026-10-05")
        XCTAssertEqual(PhoneCalendarGrouping.initialDay([cell("2026-10-01"), cell("2026-10-02")], todayISO: ""), "2026-10-01")
    }

    // MARK: Months and labels

    func testStepCrossesYears() {
        XCTAssertTrue(PhoneCalendarGrouping.step(year: 2026, month: 11, by: 1) == (2027, 0))
        XCTAssertTrue(PhoneCalendarGrouping.step(year: 2026, month: 0, by: -1) == (2025, 11))
        XCTAssertTrue(PhoneCalendarGrouping.step(year: 2026, month: 5, by: 0) == (2026, 5))
        XCTAssertTrue(PhoneCalendarGrouping.step(year: 2026, month: 1, by: -14) == (2024, 11))
        XCTAssertTrue(PhoneCalendarGrouping.step(year: 2026, month: 9, by: 15) == (2028, 0))
    }

    func testISOAndEpisodeTag() {
        XCTAssertEqual(PhoneCalendarGrouping.iso(year: 2026, month: 0, day: 7), "2026-01-07")
        XCTAssertEqual(PhoneCalendarGrouping.iso(year: 2026, month: 11, day: 31), "2026-12-31")
        XCTAssertEqual(PhoneCalendarGrouping.episodeTag(entry("e", season: 2, episode: 4)), "S2E4")
        XCTAssertNil(PhoneCalendarGrouping.episodeTag(entry("m", type: "movie")))
        XCTAssertNil(PhoneCalendarGrouping.episodeTag(entry("s", season: 1)))
    }

    func testTodayISOIsTheLocalDate() {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 9; c.hour = 23; c.minute = 30
        let late = Calendar.current.date(from: c)!
        XCTAssertEqual(PhoneCalendarGrouping.todayISO(late), "2026-03-09")
    }

    // MARK: Fixtures

    @MainActor
    func testTheFixtureMonthHasReleasesOnThreeDays() {
        let month = PhoneCalendarFixtures.month(year: 2026, month: 9)
        let days = PhoneCalendarGrouping.agenda(month.cells)
        XCTAssertEqual(days.map(\.day), PhoneCalendarFixtures.releaseDays)
        XCTAssertEqual(days.map(\.entries.count), [1, 2, 3])
        XCTAssertEqual(month.total, 6)
        XCTAssertEqual(month.status, "ready")
        XCTAssertEqual(month.cells.count, 42)
    }
}
