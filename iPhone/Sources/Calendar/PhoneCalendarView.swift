import SwiftUI

/// The Calendar chip of the Library tab: the TV's Calendar room
/// (CalendarView, the engine's `calendar.month` through the shared CalendarModel) redrawn for touch.
/// A month grid with a dot per release sits on top (swipe or the chevrons for the next month), the
/// agenda of the month's releases below it; a tapped day scrolls the agenda to it, and a release
/// pushes its title page. The source, Sub/Dub, filters, Watchlist only, week start and poster size
/// are in the options menu; the bell opens the reminders sheet (PhoneRemindersSheet). In landscape
/// the grid and the agenda sit side by side.
struct PhoneCalendarView: View {
    let open: (Meta) -> Void

    @StateObject private var model = CalendarModel()
    @Environment(\.verticalSizeClass) private var verticalSize
    /// The month shown under `--fixtures` (PhoneCalendarFixtures): the shared model is not used there.
    @State private var fixtureShown = Shown.current
    /// The day tapped in the grid; nil until one is (today or the month's first release is marked).
    @State private var selected: String?
    /// Where a month change slides the grid in from.
    @State private var slide: Edge = .trailing
    @State private var remindersOpen = false
    /// A show picked in the reminders sheet, opened once the sheet is gone.
    @State private var pendingShow: Meta?
    @State private var reminderCount = 0
    /// What the reminder runner fired since the last visit (calendar.tsx clearUnseenReminders).
    @State private var fired: [ReminderCenter.Fired] = []
    @State private var mounted = false
    @State private var retrying = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private struct Shown: Equatable {
        var year: Int
        var month: Int

        static var current: Shown {
            let now = Calendar.current.dateComponents([.year, .month], from: Date())
            return Shown(year: now.year ?? 2026, month: (now.month ?? 1) - 1)
        }
    }

    private var fixtures: Bool { PhoneCalendarFixtures.active }

    private var shown: Shown { fixtures ? fixtureShown : Shown(year: model.year, month: model.month) }

    /// The month build on screen: the fixture month, or the shared model's last read.
    private var data: CalendarModel.Month? {
        fixtures ? PhoneCalendarFixtures.month(year: fixtureShown.year, month: fixtureShown.month) : model.data
    }

    var body: some View {
        let d = data
        let ready = isReady(d)
        let cells = ready ? (d?.cells ?? []) : PhoneCalendarGrouping.blankCells(
            year: shown.year, month: shown.month, weekStartsMonday: d?.weekStartsMonday ?? false,
            todayISO: d?.todayISO ?? PhoneCalendarGrouping.todayISO())
        let days = ready && d?.status == "ready" ? PhoneCalendarGrouping.agenda(cells) : []
        let pick = selected ?? PhoneCalendarGrouping.initialDay(cells, todayISO: d?.todayISO ?? PhoneCalendarGrouping.todayISO())

        ScrollViewReader { proxy in
            let layout = verticalSize == .compact ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 10) {
                    header(d)
                    grid(cells, weekdays: d?.weekdays ?? Self.weekdayHeads, pick: pick) { iso in
                        select(iso, days: days, proxy: proxy)
                    }
                }
                .padding(.bottom, 10)
                .frame(maxWidth: verticalSize == .compact ? 380 : .infinity)
                agenda(d, ready: ready, days: days, pick: pick)
            }
            .onChange(of: shown) { _, _ in selected = nil }
            // A month that just arrived opens on today, or on its first release.
            .onChange(of: days.map(\.iso), initial: true) { _, isos in
                let opening = PhoneCalendarGrouping.initialDay(cells, todayISO: d?.todayISO ?? PhoneCalendarGrouping.todayISO())
                guard !isos.isEmpty, let target = opening.flatMap({ PhoneCalendarGrouping.anchor(for: $0, in: days) }) else { return }
                proxy.scrollTo(target, anchor: .top)
            }
        }
        .task {
            if fixtures {
                reminderCount = PhoneCalendarFixtures.reminders.count
                return
            }
            // As the TV: what fired is shown once per visit, then the month is read; back from a
            // title page the month is read again quietly (a watchlist change shows).
            if !mounted {
                mounted = true
                fired = await ReminderCenter.shared.takeUnseen()
                await model.load()
            } else {
                await model.load(quiet: true)
            }
            reminderCount = await ReminderCenter.shared.list().count
        }
        .onReceive(tick) { now = $0 }
        .sheet(isPresented: $remindersOpen, onDismiss: remindersClosed) {
            PhoneRemindersSheet(fixtures: fixtures) { pendingShow = $0 }
                .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar")
    }

    private static let weekdayHeads = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map { T($0) }

    /// The month on screen has its own build (not the last month's while the next one is read).
    private func isReady(_ d: CalendarModel.Month?) -> Bool {
        guard let d, d.year == shown.year, d.month == shown.month else { return false }
        return fixtures || model.pendingSource == nil
    }

    // MARK: Header

    private func header(_ d: CalendarModel.Month?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: T("Releases"))
                    .textCase(.uppercase)
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                    .tracking(2)
                    .foregroundStyle(BP.inkSubtle)
                Text(verbatim: monthLabel(d))
                    .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("calendar-month")
            }
            Spacer(minLength: 4)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if shown != Shown.current {
                        Button(T("Today")) { goToday() }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("calendar-today")
                    }
                    iconButton("chevron.backward", label: T("Previous month"), id: "calendar-prev") { step(-1) }
                    iconButton("chevron.forward", label: T("Next month"), id: "calendar-next") { step(1) }
                    if let d, !fixtures { optionsMenu(d) }
                    bell
                }
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 6)
    }

    private func iconButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier(id)
    }

    /// components/reminders-manager.tsx RemindersManagerButton: the bell and how many there are.
    private var bell: some View {
        Button {
            PhoneFeedback.shared.tap()
            remindersOpen = true
        } label: {
            Image(systemName: "bell")
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    if reminderCount > 0 {
                        Text(verbatim: "\(reminderCount)")
                            .font(PhoneTheme.sans(10, .bold, relativeTo: .caption2))
                            .foregroundStyle(BP.on)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(BP.accent))
                            .offset(x: 10, y: -8)
                    }
                }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(verbatim: T("Reminders")))
        .accessibilityValue(Text(verbatim: reminderCount > 0 ? "\(reminderCount)" : ""))
        .accessibilityIdentifier("calendar-reminders")
    }

    /// The TV's two chip rows in one menu: the source, then the options it offers.
    private func optionsMenu(_ d: CalendarModel.Month) -> some View {
        Menu {
            if d.sources.count > 1 {
                Picker(T("Source"), selection: Binding(get: { model.pendingSource ?? d.source }, set: { model.set(source: $0) })) {
                    ForEach(d.sources) { s in Label(s.label, systemImage: s.icon).tag(s.id) }
                }
            }
            if d.animeDubToggle {
                Picker(T("Sub / Dub"), selection: Binding(get: { d.animeDub }, set: { model.set(animeDub: $0) })) {
                    Text(verbatim: T("Sub")).tag(false)
                    Text(verbatim: T("Dub")).tag(true)
                }
            }
            if !d.filters.isEmpty {
                Picker(T("Show"), selection: Binding(get: { d.filter }, set: { model.set(filter: $0) })) {
                    ForEach(d.filters) { f in Text(verbatim: "\(f.label) (\(f.count))").tag(f.id) }
                }
            }
            if d.watchlistToggle {
                Toggle(isOn: Binding(get: { d.watchlistOnly }, set: { _ in model.toggleWatchlist() })) {
                    Label(T("Watchlist only"), systemImage: "star")
                }
                .disabled(!d.signedIn)
                if !d.signedIn { Text(verbatim: T("Sign in to filter by your library")) }
            }
            if let custom = d.custom, !custom.summary.isEmpty {
                Section(T("Filters")) { Text(verbatim: custom.summary) }
            }
            Section {
                Toggle(T("Start week on Monday"), isOn: Binding(get: { d.weekStartsMonday }, set: { _ in model.toggleWeekStart() }))
                Picker(T("Poster size"), selection: Binding(get: { d.posterSize == "large" ? "large" : "default" }, set: { model.set(posterSize: $0) })) {
                    Text(verbatim: T("Default")).tag("default")
                    Text(verbatim: T("Large")).tag("large")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(verbatim: T("Calendar options")))
        .accessibilityIdentifier("calendar-options")
    }

    private func monthLabel(_ d: CalendarModel.Month?) -> String {
        if let d, d.year == shown.year, d.month == shown.month { return d.monthLabel }
        var c = DateComponents()
        c.year = shown.year; c.month = shown.month + 1; c.day = 1
        guard let date = Calendar.current.date(from: c) else { return "" }
        return date.formatted(.dateTime.month(.wide).year().locale(L10n.locale))
    }

    // MARK: Month grid

    private func grid(_ cells: [CalendarModel.Cell], weekdays: [String], pick: String?, tap: @escaping (String) -> Void) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, w in
                    Text(verbatim: String(w.prefix(3)).uppercased())
                        .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                        .tracking(1)
                        .foregroundStyle(BP.inkSubtle)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 2) {
                // A trailing week of only next month's days is left off: the agenda gets the room.
                ForEach(Array(PhoneCalendarGrouping.weeks(cells).filter { $0.contains(where: \.inMonth) }.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(week) { cell in
                            PhoneCalendarDay(cell: cell, selected: cell.inMonth && cell.iso == pick) { tap(cell.iso) }
                                // The 30 s clock tick and a day pick re-run this grid: only the cells whose
                                // content or pick changed redraw (the tap closure is not compared).
                                .equatable()
                        }
                    }
                }
            }
            .id(shown.year * 12 + shown.month)
            .transition(PhoneMotion.reduced ? .opacity
                : .asymmetric(insertion: .move(edge: slide).combined(with: .opacity),
                              removal: .move(edge: slide == .trailing ? .leading : .trailing).combined(with: .opacity)))
        }
        .padding(.horizontal, PhoneTheme.margin - 4)
        .clipped()
        .contentShape(Rectangle())
        // Swipe left for the next month, right for the one before (alongside the days' taps: a swipe
        // that ends off the day it started on taps nothing).
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { drag in
                    let dx = drag.translation.width
                    guard abs(dx) > 50, abs(dx) > abs(drag.translation.height) * 1.5 else { return }
                    step(dx < 0 ? 1 : -1)
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-grid")
    }

    private func step(_ by: Int) {
        PhoneFeedback.shared.selection()
        slide = by > 0 ? .trailing : .leading
        withMotion(.snappy(duration: 0.3)) {
            if fixtures {
                let next = PhoneCalendarGrouping.step(year: fixtureShown.year, month: fixtureShown.month, by: by)
                fixtureShown = Shown(year: next.year, month: next.month)
            } else if by > 0 {
                model.next()
            } else {
                model.prev()
            }
        }
    }

    private func goToday() {
        let today = Shown.current
        guard shown != today else { return }
        PhoneFeedback.shared.selection()
        slide = (shown.year, shown.month) < (today.year, today.month) ? .trailing : .leading
        withMotion(.snappy(duration: 0.3)) {
            if fixtures { fixtureShown = today } else { model.today() }
        }
    }

    /// A tapped day is marked and the agenda scrolls to it (or to the next day with releases).
    private func select(_ iso: String, days: [PhoneCalendarGrouping.Day], proxy: ScrollViewProxy) {
        PhoneFeedback.shared.selection()
        selected = iso
        guard let target = PhoneCalendarGrouping.anchor(for: iso, in: days) else { return }
        withMotion(.snappy) { proxy.scrollTo(target, anchor: .top) }
    }

    // MARK: Agenda

    @ViewBuilder private func agenda(_ d: CalendarModel.Month?, ready: Bool, days: [PhoneCalendarGrouping.Day], pick: String?) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if !fired.isEmpty { firedBanner }
                agendaContent(d, ready: ready, days: days, pick: pick)
            }
            .padding(.bottom, 24)
        }
        .background(alignment: .top) { Rectangle().fill(BP.ink.opacity(0.08)).frame(height: 1) }
        .accessibilityIdentifier("calendar-agenda")
    }

    @ViewBuilder private func agendaContent(_ d: CalendarModel.Month?, ready: Bool, days: [PhoneCalendarGrouping.Day], pick: String?) -> some View {
        if let message = errorMessage(d) {
            ErrorPlate(title: T("Couldn't load the calendar"), message: message, retry: retry)
                .padding(.top, 20)
        } else if let d, ready, !(model.loading && !fixtures && d.total == 0) {
            switch d.status {
            case "not-signed-in":
                statusCard("Sign in to see your library calendar",
                           "My Library shows upcoming episodes from the shows you've saved on Stremio. Sign in to wire it up.")
            case "no-key":
                statusCard("All upcoming needs a TMDB key",
                           "TMDB powers the firehose of every release this month. The free tier covers it. About 60 seconds to set up. Switch to My Library if you'd rather only see what you've saved.")
            default:
                if days.isEmpty {
                    statusCard(d.emptyHeading, d.emptyBody)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                // Keyed by day and place: one LazyVStack holds every section, and ids
                                // repeated across them (offsets alone) left rows blank.
                                ForEach(day.rows) { row in
                                    PhoneAgendaRow(entry: row.entry, hideTypeTag: d.hideTypeTag, large: d.posterSize == "large", now: now) {
                                        open(row.entry.meta)
                                    }
                                }
                            } header: {
                                dayHeader(day, marked: day.iso == pick)
                            }
                            .id(day.iso)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        } else {
            // calendar-skeleton.tsx: a few rows while the month is read.
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(width: 180, height: 18, radius: 6)
                ForEach(0..<3, id: \.self) { _ in SkeletonBlock(height: 84) }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.top, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: T("Loading")))
        }
    }

    /// empty-states.tsx EmptyShell, with the TV's copy.
    private func statusCard(_ heading: String, _ body: String) -> some View {
        EmptyState(title: T(heading), message: body.isEmpty ? nil : T(body), systemImage: "calendar")
            .padding(.top, 12)
    }

    /// The day's name over its releases; pinned while its rows scroll.
    private func dayHeader(_ day: PhoneCalendarGrouping.Day, marked: Bool) -> some View {
        let title = day.entries.first?.dateLong ?? day.iso
        let count = TCount(day.entries.count, one: "%lld title", "%lld titles")
        return HStack(spacing: 8) {
            Text(verbatim: title)
                .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                .foregroundStyle(marked ? BP.on : BP.ink)
                .lines(1)
            if day.isToday {
                Text(verbatim: T("Today"))
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                    .foregroundStyle(marked ? BP.on : BP.accent)
            }
            Spacer(minLength: 4)
            Text(verbatim: count)
                .font(PhoneTheme.sans(12, .medium, relativeTo: .caption))
                .foregroundStyle(marked ? BP.on.opacity(0.8) : BP.inkSubtle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(marked ? Glass.regular.tint(BP.accent) : Glass.regular, in: .capsule)
        .padding(.horizontal, PhoneTheme.margin - 6)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityAddTraits(marked ? [.isSelected] : [])
        .accessibilityIdentifier("calendar-agenda-\(day.iso)")
    }

    /// tvOS: lib/reminders-runner.tsx fired these while the viewer was elsewhere; the first visit
    /// after lists them once, as it clears the badge.
    private var firedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: T("Reminders"))
                    .textCase(.uppercase)
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                    .tracking(2)
                    .foregroundStyle(BP.inkSubtle)
                Spacer()
                Button(T("Dismiss")) { withMotion { fired = [] } }
                    .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(BP.accent)
            }
            ForEach(fired) { f in
                Button {
                    open(Meta(id: f.id, type: "series", name: f.name, poster: f.poster))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge").foregroundStyle(BP.accent).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: f.name).font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline)).foregroundStyle(BP.ink)
                            Text(verbatim: f.body).font(PhoneTheme.sans(13, .regular, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                        }
                        .lines(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle(scale: 0.98))
            }
        }
        .padding(14)
        .phoneGlassPlate(radius: PhoneTheme.radiusMedium)
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 10)
    }

    // MARK: Reading

    /// The TV's error card cases: the newest read failed and left no build for this month, or the
    /// build itself says "error".
    private func errorMessage(_ d: CalendarModel.Month?) -> String? {
        guard !fixtures else { return nil }
        if model.failed, !model.loading || retrying {
            guard let d else { return T("Failed to load") }
            if d.year != model.year || d.month != model.month { return T("Failed to load") }
        }
        guard let d, d.status == "error", model.pendingSource == nil,
              !(model.loading && (d.year != model.year || d.month != model.month)) else { return nil }
        return d.error ?? T("Failed to load")
    }

    private func retry() {
        guard !retrying else { return }
        retrying = true
        Task {
            await model.load()
            retrying = false
        }
    }

    private func remindersClosed() {
        Task {
            reminderCount = fixtures ? PhoneCalendarFixtures.reminders.count : await ReminderCenter.shared.list().count
        }
        if let show = pendingShow {
            pendingShow = nil
            open(show)
        }
    }
}

/// One day of the grid: its number (ringed for today, filled when picked) and a dot per release
/// in the release's type colour (calendar-chip.tsx tagClass), at most three.
private struct PhoneCalendarDay: View, Equatable {
    let cell: CalendarModel.Cell
    let selected: Bool
    let tap: () -> Void

    static func == (a: PhoneCalendarDay, b: PhoneCalendarDay) -> Bool {
        a.cell == b.cell && a.selected == b.selected
    }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Text(verbatim: "\(cell.day)")
                    .font(PhoneTheme.sans(16, cell.isToday || selected ? .bold : .medium, relativeTo: .body))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                    .frame(width: 34, height: 34)
                    .background {
                        if selected {
                            Circle().fill(BP.accent)
                        } else if cell.isToday {
                            Circle().strokeBorder(BP.accent, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 3) {
                    ForEach(Array(PhoneCalendarGrouping.dots(cell).enumerated()), id: \.offset) { _, entry in
                        Circle().fill(entry.tagColor).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
            .opacity(cell.inMonth ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!cell.inMonth)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: releases))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("calendar-day-\(cell.iso)")
    }

    private var numberColor: Color {
        if selected { return BP.on }
        if cell.isToday { return BP.accent }
        return cell.inMonth ? BP.ink : BP.inkSubtle
    }

    private var label: String { Self.label(cell.iso) }

    /// "Tuesday, October 21" per day. Building a date style and formatting it costs ~0.2 ms; a month grid
    /// asks for 42 of them on every redraw, so each is made once per language.
    private static var labels: [String: String] = [:]

    private static func label(_ iso: String) -> String {
        let key = "\(L10n.locale.identifier)|\(iso)"
        if let hit = labels[key] { return hit }
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return iso }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        guard let date = Calendar.current.date(from: c) else { return iso }
        let text = date.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(L10n.locale))
        if labels.count > 800 { labels.removeAll() }
        labels[key] = text
        return text
    }

    /// "2 releases", or nothing on a day without.
    private var releases: String {
        cell.items.isEmpty ? "" : TCount(cell.items.count, one: "%lld release", "%lld releases")
    }
}

/// One release in the agenda (calendar/day-modal.tsx's row): the poster, the type tag and episode,
/// the name, the air time with the countdown while it is ahead, and two lines of overview. A tap
/// pushes the title page; a long press has the title menu every tile has.
private struct PhoneAgendaRow: View {
    let entry: CalendarModel.Entry
    let hideTypeTag: Bool
    let large: Bool
    let now: Date
    let tap: () -> Void
    /// The poster's zoom source id: the title page opens out of it.
    @State private var zoomKey = UUID().uuidString
    @Environment(\.phoneZoom) private var zoom

    var body: some View {
        Button {
            zoom?.arm(zoomKey)
            tap()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    PhoneImage(url: entry.poster)
                    if entry.poster == nil {
                        Image(systemName: entry.type == "movie" ? "film" : "tv")
                            .foregroundStyle(BP.inkSubtle)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: large ? 64 : 48, height: large ? 96 : 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .modifier(PhoneZoomSource(key: zoomKey))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if !hideTypeTag { typeTag }
                        if let tag = PhoneCalendarGrouping.episodeTag(entry) {
                            Text(verbatim: tag)
                                .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
                                .foregroundStyle(BP.inkMuted)
                        }
                        if entry.rating > 0 {
                            Text(verbatim: "★ " + String(format: "%.1f", entry.rating))
                                .font(PhoneTheme.sans(12, .medium, relativeTo: .caption))
                                .foregroundStyle(BP.inkSubtle)
                        }
                    }
                    Text(verbatim: entry.name)
                        .font(PhoneTheme.sans(16, .semibold, relativeTo: .headline))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                        .multilineTextAlignment(.leading)
                    if let time = entry.releaseTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock").accessibilityHidden(true)
                            Text(verbatim: time)
                            if let left = AiringCountdown.suffix(entry.releaseAtMs, now: now) {
                                Text(verbatim: "· \(left)").foregroundStyle(BP.accent)
                            }
                        }
                        .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                        .foregroundStyle(BP.inkSubtle)
                    }
                    if let overview = entry.overview, !overview.isEmpty {
                        Text(verbatim: overview)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                            .lines(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BP.inkSubtle)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.ink.opacity(0.05)))
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .padding(.horizontal, PhoneTheme.margin)
        .phoneContextMenu(for: entry.meta, open: { _ in tap() })
        .accessibilityIdentifier("calendar-entry-\(entry.id)")
    }

    /// calendar-chip.tsx tag: Anime / Movie / TV in its colour.
    private var typeTag: some View {
        Text(verbatim: entry.tag.uppercased())
            .font(PhoneTheme.sans(10, .bold, relativeTo: .caption2))
            .tracking(0.8)
            .foregroundStyle(entry.tagColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(entry.tagColor.opacity(0.2)))
    }
}
