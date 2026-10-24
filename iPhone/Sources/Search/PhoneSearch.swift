import SwiftUI

/// The Search tab: the iOS 26 search field the `.search` tab role brings,
/// recent searches while it is empty, then the results grouped as the TV groups them (Movies, Shows,
/// people, Anime, franchises, one rail per addon), and the AI search section; a person pushes their
/// page (PhonePersonPage). The data is the TV's own `SearchModel` (180 ms debounce, the engine
/// fan-out) and `AISearchModel`, kept by the `ShellViewState` so a query survives a tab switch.
/// Live TV channels, collections and the "Addons you could install" row wait for the screens they
/// open (Live TV, Collections, Addons).
struct PhoneSearchView: View {
    @ObservedObject private var model: SearchModel
    @ObservedObject private var ai: AISearchModel
    /// Opens a title; an AI episode pick passes the episode the page should land on.
    let open: (Meta, PhoneEpisodeHint?) -> Void

    @EnvironmentObject private var app: AppModel
    /// The tab's stack: a people hit pushes its page there (`PhoneRoute.person`).
    @EnvironmentObject private var nav: PhoneNavigator

    init(views: ShellViewState, open: @escaping (Meta, PhoneEpisodeHint?) -> Void) {
        _model = ObservedObject(wrappedValue: views.search)
        _ai = ObservedObject(wrappedValue: views.ai)
        self.open = open
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if ai.available { aiBar }
                if ai.available && ai.aiMode {
                    aiSection
                } else {
                    resultsBody
                }
            }
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $model.query, prompt: T("Search Harbor"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        // search-overlay.tsx: Enter in AI mode asks the model straight away.
        .onSubmit(of: .search) { submit() }
        .onChange(of: model.query) { _, q in ai.queryChanged(q) }
        .task { await start() }
        .task { await loadSuggested() }
        .accessibilityIdentifier("search-screen")
    }

    // MARK: Start

    /// A quick-panel seed or `--query` fills the field; the AI model's state is read once per visit.
    private func start() async {
        if model.query.isEmpty {
            if let seed = app.searchSeed {
                model.query = seed
                app.searchSeed = nil
            } else if let q = Fixtures.query {
                model.query = q
            }
        }
        if ai.state == nil { await ai.load() }
    }

    private func loadSuggested() async {
        guard !SearchModel.usesFixtures else { return }
        await model.loadSuggestions()
    }

    private func submit() {
        ai.queryChanged(model.query)
        if ai.aiMode { ai.runNow() }
    }

    /// Opening a result is what files the query under Recent (search-context recordRecent).
    private func select(_ meta: Meta, hint: PhoneEpisodeHint? = nil) {
        model.commitRecent()
        open(meta, hint)
    }

    /// ai-result-list.tsx: an episode pick opens its show on that season with the episode marked
    /// (views/detail.tsx episodeHint).
    private func select(_ result: AISearchModel.Result) {
        if let s = result.season, let e = result.episode {
            select(result.meta, hint: PhoneEpisodeHint(season: s, episode: e))
        } else {
            select(result.meta)
        }
    }

    private var trimmedQuery: String { model.query.trimmingCharacters(in: .whitespaces) }

    // MARK: Results

    @ViewBuilder private var resultsBody: some View {
        switch model.status {
        case .idle:
            idle
        case .typing:
            searching
        case .failed(let why):
            ErrorPlate(title: T("Couldn't search"), message: why) { model.retry() }
                .padding(.top, 24)
        case .loading, .done:
            found
        }
    }

    @ViewBuilder private var found: some View {
        if model.settled && model.distinctCount(nil) == 0 {
            if model.addonsFailed.isEmpty {
                EmptyState(title: T("No results"), message: emptyMessage, systemImage: "magnifyingglass")
                    .padding(.top, 24)
            } else {
                // bp-search-empty action: Try again when addons did not answer.
                EmptyState(title: T("No results"), message: emptyMessage, systemImage: "magnifyingglass",
                           actionTitle: T("Try again"), action: { model.retry() })
                    .padding(.top, 24)
            }
        } else {
            chipStrip
            resultNotes
            if model.promotePerson { peopleRail }
            ForEach(titleRows) { row in titleRail(row) }
            if !model.promotePerson { peopleRail }
            ForEach(animeRows) { row in titleRail(row) }
            ForEach(franchiseRows) { row in titleRail(row) }
            addonRails
            if model.busy { searchingNote }
        }
    }

    /// bp-search-empty.tsx bpSearchEmptyMessage: TMDB down and addons that never answered are said
    /// as such, not as a query that exists nowhere.
    private var emptyMessage: String {
        let q = trimmedQuery
        if model.tmdbUnavailable { return T("TMDB is temporarily unavailable. Try your search again shortly.") }
        let failed = model.addonsFailed.count
        if failed > 0 { return T("Nothing found for \"%@\". %lld of your addons did not answer.", q, failed) }
        return T("Nothing found for \"%@\"", q)
    }

    @ViewBuilder private var resultNotes: some View {
        if model.status == .done, model.tmdbUnavailable, model.distinctCount(nil) > 0 {
            note(T("TMDB is temporarily unavailable, so these results may be incomplete."))
        }
        if model.filterStale {
            note(T("Nothing in this filter. Choose All to see everything that answered."))
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
            .foregroundStyle(BP.inkMuted)
            .padding(.horizontal, PhoneTheme.margin)
    }

    // MARK: Chips

    /// The kind chips (use-bp-search chips). Live TV and Collections have no screen yet, so no chip.
    private var chips: [SearchModel.Chip] {
        model.chips.filter { $0.filter != .livetv && $0.filter != .collections }
    }

    private func chipLabel(_ filter: SearchModel.Filter) -> String {
        filter == .series ? T("Shows") : T(filter.label)
    }

    @ViewBuilder private var chipStrip: some View {
        if chips.count > 1 {
            ChipRow {
                ForEach(chips) { chip in
                    GlassChip(title: "\(chipLabel(chip.filter)) \(chip.count)", selected: model.filter == chip.filter) {
                        PhoneFeedback.shared.selection()
                        model.filter = chip.filter
                    }
                }
            }
            .accessibilityIdentifier("search-chips")
        }
    }

    // MARK: Rails

    /// Movies and Series rows under the active chip.
    private var titleRows: [BrowseRow] {
        model.rows.filter { ($0.key == "movies" || $0.key == "series") && model.shows(SearchModel.group(ofRow: $0.key)) }
    }

    private var animeRows: [BrowseRow] {
        model.rows.filter { $0.key == "anime" && model.shows(.anime) }
    }

    /// One franchise row per character hit (AniList).
    private var franchiseRows: [BrowseRow] {
        model.rows.filter { $0.key.hasPrefix("character:") && model.shows(.characters) }
    }

    private func titleRail(_ row: BrowseRow) -> some View {
        Rail(row.key == "series" ? T("Shows") : row.title) {
            ForEach(row.metas) { meta in
                PosterTile(meta: meta) { select(meta) }
            }
        }
    }

    @ViewBuilder private var peopleRail: some View {
        if model.shows(.people) && !model.people.isEmpty {
            Rail(T("People")) {
                ForEach(model.people) { person in
                    PersonTile(person: person) {
                        // As the TV's SearchView: a hit without a TMDB id has no page to open.
                        guard let id = person.tmdbId else { return }
                        model.commitRecent()
                        nav.push(PhoneRoute.person(id: id, name: person.name))
                    }
                }
            }
        }
    }

    /// bp-search-results: one fixed slot per addon, in installed order. A slot with titles is its
    /// rail; pending holds quiet plates, failed says it did not answer, with Try again; one that
    /// settled empty collapses.
    @ViewBuilder private var addonRails: some View {
        if model.shows(.addons) {
            ForEach(model.addonSlots) { slot in
                if let row = model.rows.first(where: { $0.key == "addon:" + slot.id }) {
                    titleRail(row)
                } else if slot.state == "pending" {
                    pendingRail(slot.name)
                } else if slot.state == "failed" {
                    failedPlate(slot.name)
                }
            }
            // Addon rows that answered with no announced slot (an engine without addonQueries).
            ForEach(unslottedAddonRows) { row in titleRail(row) }
        }
    }

    private var unslottedAddonRows: [BrowseRow] {
        let slotted: Set<String> = Set(model.addonSlots.map { "addon:" + $0.id })
        return model.rows.filter { $0.key.hasPrefix("addon:") && !slotted.contains($0.key) }
    }

    private func pendingRail(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(width: 140, height: 20)
                .padding(.horizontal, PhoneTheme.margin)
            HStack(spacing: PhoneTheme.railGap) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock(width: PhoneTheme.posterWidth, height: PhoneTheme.posterWidth * 1.5)
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: T("Searching %@", name)))
        .accessibilityIdentifier("search-pending")
    }

    private func failedPlate(_ name: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(BP.ink)
                Text(T("Didn't answer"))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
            }
            Spacer(minLength: 8)
            Button(T("Try again")) { model.retry() }
                .buttonStyle(.glass)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .phoneGlassPlate()
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-failed")
    }

    // MARK: Idle, searching

    @ViewBuilder private var idle: some View {
        if !model.recent.isEmpty { recents }
        if !model.suggestions.isEmpty {
            Rail(T("Suggested")) {
                ForEach(model.suggestions) { meta in
                    PosterTile(meta: meta) { select(meta) }
                }
            }
        }
        if model.recent.isEmpty && model.suggestions.isEmpty && (model.suggestionsLoaded || SearchModel.usesFixtures) {
            EmptyState(title: T("Search Harbor"),
                       message: T("Find movies, shows, anime and people."),
                       systemImage: "magnifyingglass")
                .padding(.top, 40)
        }
    }

    /// search-context RECENT_KEY: the last eight queries that found something.
    private var recents: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: T("Recent"), actionTitle: T("Clear"), action: { model.clearRecent() })
            ForEach(model.recent, id: \.self) { query in
                HStack(spacing: 4) {
                    Button { model.query = query } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(BP.inkMuted)
                                .accessibilityHidden(true)
                            Text(verbatim: query)
                                .font(PhoneTheme.sans(16, .medium, relativeTo: .body))
                                .foregroundStyle(BP.ink)
                                .lines(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.98))
                    .accessibilityIdentifier("recent-\(query)")
                    Button { model.removeRecent(query) } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(BP.inkMuted)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: T("Remove %@", query)))
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.ink.opacity(0.06)))
                .padding(.horizontal, PhoneTheme.margin)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-recent")
    }

    private var searching: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchingNote
            pendingRail("")
        }
    }

    private var searchingNote: some View {
        HStack(spacing: 10) {
            ProgressView().tint(BP.accent).accessibilityHidden(true)
            Text(T("Searching…"))
                .font(PhoneTheme.sans(14, .medium, relativeTo: .footnote))
                .foregroundStyle(BP.inkMuted)
        }
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search-searching")
    }

    // MARK: AI search

    /// ai-mode-button.tsx: the AI chip turns AI mode on and off; the menu beside it picks the model
    /// (the TV's held Select).
    private var aiBar: some View {
        ChipRow {
            GlassChip(title: T("AI search"), systemImage: "sparkles", selected: ai.aiMode) {
                PhoneFeedback.shared.selection()
                ai.aiMode.toggle()
            }
            if !ai.menu.isEmpty {
                Menu {
                    Section(T("AI model")) {
                        ForEach(ai.menu) { m in
                            Button {
                                Task { await ai.selectModel(m.id) }
                            } label: {
                                if m.id == ai.state?.model {
                                    Label(m.label, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: m.free ? "\(m.label) · \(m.provider == "groq" ? T("Free tier") : T("Free"))" : m.label)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BP.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .accessibilityLabel(Text(T("AI model")))
                .accessibilityIdentifier("search-ai-model")
            }
        }
        .accessibilityIdentifier("search-ai-bar")
    }

    /// ai-search-section.tsx in AI mode: the add-a-key note, "Searches when you stop typing", the
    /// thinking state, the retry card and the picks.
    @ViewBuilder private var aiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if ai.state?.hasKey != true {
                aiNote(ai.state?.tab == "groq"
                       ? T("Add your Groq API key in Settings, AI search to use this model.")
                       : T("Add your OpenRouter API key in Settings, AI search to use this model."))
            } else if trimmedQuery.isEmpty {
                // search-overlay.tsx AiExampleHint: a sample request, every 6 s.
                TimelineView(.periodic(from: .now, by: 6)) { context in
                    let examples = AISearchModel.examples
                    let sample: String = examples[Int(context.date.timeIntervalSince1970 / 6) % examples.count]
                    VStack(spacing: 8) {
                        Text(T("Describe what you want to watch"))
                            .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                            .foregroundStyle(BP.ink)
                        Text(verbatim: "\"" + T(sample) + "\"")
                            .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                            .foregroundStyle(BP.accent)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
                .accessibilityIdentifier("search-ai-hint")
            } else {
                switch ai.status {
                case .idle:
                    VStack(spacing: 12) {
                        Text(T("Searches when you stop typing"))
                            .font(PhoneTheme.sans(16, .medium, relativeTo: .callout))
                            .foregroundStyle(BP.accent)
                        Button {
                            submit()
                            ai.runNow()
                        } label: {
                            Label(T("Ask AI"), systemImage: "sparkles")
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("search-ai-run")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                case .loading:
                    PhoneAIThinking(label: ai.state?.label.isEmpty == false ? (ai.state?.label ?? "") : T("AI search"),
                                    phrases: ai.thinkingPhrases)
                case .error:
                    aiError
                case .done:
                    aiPicks
                }
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-ai-section")
    }

    private func aiNote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
            .foregroundStyle(BP.inkMuted)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.ink.opacity(0.06)))
            .accessibilityIdentifier("search-ai-note")
    }

    private var aiError: some View {
        Button {
            submit()
            ai.runNow()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(T("AI search failed. Tap to retry."))
                    .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(BP.ink)
                Text(verbatim: ai.errorMessage ?? T("AI search failed."))
                    .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                if let detail = ai.errorDetail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                        .foregroundStyle(BP.inkSubtle)
                        .lines(3)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.danger.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).stroke(BP.danger.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityIdentifier("search-ai-error")
    }

    @ViewBuilder private var aiPicks: some View {
        if ai.ranQuery == trimmedQuery {
            if ai.results.isEmpty {
                aiNote(T("AI didn't find anything for that. Try rephrasing."))
            } else {
                // ai-picks-header.tsx: "AI picks", the model and its maker, the count.
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(BP.accent).accessibilityHidden(true)
                    Text(T("AI picks"))
                        .font(PhoneTheme.display(20, .semibold, relativeTo: .title3))
                        .foregroundStyle(BP.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let state = ai.state {
                        Text(verbatim: "\(state.label) · \(state.providerName)")
                            .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                            .foregroundStyle(BP.inkSubtle)
                            .lines(1)
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: "\(ai.results.count)")
                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                        .monospacedDigit()
                        .foregroundStyle(BP.inkSubtle)
                }
                ForEach(ai.results) { result in
                    Button { select(result) } label: { PhoneAIResultRow(result: result) }
                        .buttonStyle(PressScaleStyle(scale: 0.98))
                        .accessibilityIdentifier("ai-result-\(result.meta.id)")
                }
            }
        }
    }
}

/// One person hit: a round photo, the name and what they are known for.
private struct PersonTile: View {
    let person: SearchModel.Results.Person
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    PhoneImage(url: person.profile)
                    if person.profile == nil {
                        Image(systemName: "person.fill")
                            .font(.title2)
                            .foregroundStyle(BP.inkMuted)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                Text(verbatim: person.name)
                    .font(PhoneTheme.sans(13, .semibold, relativeTo: .caption))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                if let known = person.knownFor, !known.isEmpty {
                    Text(verbatim: known)
                        .font(PhoneTheme.sans(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(BP.inkSubtle)
                        .lines(1)
                }
            }
            .frame(width: 104)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: person.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("person-\(person.name)")
    }
}

/// ai-result-list.tsx AiResultRow: poster, an S · E badge for an episode pick, the title (the
/// episode's own for an episode), the show, year and rating, and the overview for a title.
private struct PhoneAIResultRow: View {
    let result: AISearchModel.Result

    var body: some View {
        let meta = result.meta
        HStack(alignment: .top, spacing: 14) {
            PhoneImage(url: meta.poster)
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                if result.isEpisode {
                    Text(T("S%lld · E%lld", result.season ?? 0, result.episode ?? 0))
                        .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                        .textCase(.uppercase)
                        .foregroundStyle(BP.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(BP.accent.opacity(0.15)))
                }
                Text(verbatim: result.isEpisode ? (result.episodeTitle ?? meta.name) : meta.name)
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if result.isEpisode { Text(verbatim: meta.name).lines(1) }
                    if let year = meta.releaseInfo, !year.isEmpty { Text(verbatim: year) }
                    if let rating = meta.imdbRating, !rating.isEmpty {
                        Label(rating, systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(BP.ink)
                    }
                }
                .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                .foregroundStyle(BP.inkMuted)
                if !result.isEpisode, let overview = meta.description, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(BP.inkSubtle)
                        .lines(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// ai-thinking.tsx: the model's name over a status line that changes every 1.4 s, then skeleton
/// rows where the picks will land.
private struct PhoneAIThinking: View {
    let label: String
    let phrases: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView().tint(BP.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label)
                        .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
                        .textCase(.uppercase)
                        .foregroundStyle(BP.accent)
                    TimelineView(.periodic(from: .now, by: 1.4)) { context in
                        let phrase: String = phrases.isEmpty ? "" : phrases[Int(context.date.timeIntervalSinceReferenceDate / 1.4) % phrases.count] + "…"
                        Text(verbatim: phrase)
                            .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 14) {
                    SkeletonBlock(width: 64, height: 96)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: 180, height: 14)
                        SkeletonBlock(width: 240, height: 12)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("search-ai-thinking")
    }
}
