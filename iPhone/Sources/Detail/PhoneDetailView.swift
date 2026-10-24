import SwiftUI

/// The title page over
/// the shared `DetailModel`: a stretchy backdrop with the logo and facts line, the glass action bar
/// (Play / Resume, Watchlist, Rate, Trailer, Share, More), the synopsis, the season menu and episode
/// rows, awards and details, the cast rail, the gallery and videos, and the related rails. Every tile,
/// hero and link that opens a title pushes this page (PhoneNavigator.open); a harbor://detail link
/// shows it in a sheet (PhoneDetailSheet). Playback goes through `PhonePlay` (the play picker), a cast
/// member opens PhonePersonPage, the gallery its lightbox, and the dialogs (trailer, Rate, lists,
/// facts, awards, trackers) are sheets through `PhoneDetailDialog`.
struct PhoneDetailView: View {
    let target: PhoneDetailTarget
    /// Set when the page is the root of the deep-link sheet: it draws a close button.
    var close: (() -> Void)?

    @StateObject private var model: DetailModel
    @EnvironmentObject private var nav: PhoneNavigator
    /// The page re-runs `.task` each time it comes back on screen (a pushed page popped): the load
    /// is repeated (resume and marks refresh), the hint's season and scroll happen once.
    @State private var didFirstLoad = false
    /// Something was played from the page: the opening hint is spent (DetailView's hintSpent).
    @State private var hintSpent = false
    @State private var highlighted: PhoneEpisodeHint?
    @State private var synopsisOpen = false
    @State private var dialog: PhoneDetailDialog?
    /// `--fixtures detail` has no TMDB: the title's extras and awards come from PhoneDetailFixtures.
    @State private var fixtureExtras: DetailModel.Extras?
    @State private var fixtureAwards: DetailModel.TitleAwards?
    /// The header has scrolled under the bar: the title shows in it.
    @State private var scrolledPast = false
    /// `target.autoPlay` has opened the picker (DetailView's autoPlayFired): once per page.
    @State private var autoPlayFired = false

    private static let headerHeight: CGFloat = 470

    init(target: PhoneDetailTarget, close: (() -> Void)? = nil) {
        self.target = target
        self.close = close
        _model = StateObject(wrappedValue: DetailModel(meta: target.meta))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 28) {
                        actionBar
                        synopsis
                        // bp-detail's BpPageMessage, where the episodes would be (a film still plays).
                        if model.isSeries, model.metaFailed, model.episodes.isEmpty {
                            ErrorPlate(title: T("Couldn't load this title.")) {
                                Task { await model.load() }
                            }
                            .padding(.horizontal, PhoneTheme.margin)
                        }
                        if model.isSeries, !model.seasonEpisodes.isEmpty { episodesSection }
                        linksRow
                        awardsRow
                        castRail
                        crewLines
                        charactersRail
                        if showGallery { PhoneGalleryRail(meta: model.meta) }
                        videosRail
                        relatedRails
                        tmdbNote
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 48)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > Self.headerHeight - 140
            } action: { _, past in
                withMotion(.easeOut(duration: 0.2)) { scrolledPast = past }
            }
            .task { await firstLoad(proxy) }
            // bp-detail's pending-play effect: playback opens once the page knows what Play starts.
            .onChange(of: model.loadStage) { _, _ in fireAutoPlayIfReady() }
        }
        .overlay(alignment: .top) { barShade }
        .background(PhoneBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $dialog, onDismiss: dialogClosed) { d in
            dialogSheet(d)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-page")
    }

    // MARK: load

    private func firstLoad(_ proxy: ScrollViewProxy) async {
        if PhoneDetailFixtures.active, fixtureExtras == nil {
            fixtureExtras = PhoneDetailFixtures.extras(for: model.meta)
            fixtureAwards = PhoneDetailFixtures.awards()
        }
        model.episodeHintSeason = target.hint?.season
        model.episodeHint = hintSpent ? nil : target.hint.map { (season: $0.season, episode: $0.episode) }
        let first = !didFirstLoad
        didFirstLoad = true
        await model.load()
        // Normally fired from the stage change already; this catches a load that finished first.
        fireAutoPlayIfReady()
        guard first, let h = target.hint, model.seasons.contains(h.season) else { return }
        model.pickKitsuSeason(h.season)
        guard model.episodes.contains(where: { $0.season == h.season && $0.episode == h.episode }) else { return }
        highlighted = h
        // The rows of the new season lay out first.
        try? await Task.sleep(for: .milliseconds(350))
        withMotion(.easeInOut(duration: 0.4)) { proxy.scrollTo(Self.rowId(h.season, h.episode), anchor: .center) }
    }

    /// A Continue Watching resume or the hero's Play (`target.autoPlay`): the picker opens once, the
    /// first time the page knows what Play starts (DetailView.fireAutoPlayIfReady on the TV).
    private func fireAutoPlayIfReady() {
        guard target.autoPlay, !autoPlayFired, model.knowsPlayTarget() else { return }
        autoPlayFired = true
        play()
    }

    private static func rowId(_ season: Int, _ episode: Int) -> String { "row-\(season)-\(episode)" }

    // The fixtures win: offline, the engine still answers with an empty title (no awards, no cast).
    private var extras: DetailModel.Extras? { fixtureExtras ?? model.extras }
    private var awards: DetailModel.TitleAwards? { fixtureAwards ?? model.awards }
    private var trailerYtId: String? { fixtureExtras?.trailerYtId ?? model.trailerYtId }

    // MARK: dialogs

    @ViewBuilder private func dialogSheet(_ d: PhoneDetailDialog) -> some View {
        let close = { dialog = nil }
        switch d {
        case .trailer(let yt, let name):
            PhoneTrailerSheet(ytId: yt, title: model.meta.name, clipName: name, close: close)
        case .rate:
            PhoneRateSheet(meta: model.meta, close: close)
        case .lists:
            PhoneListSheet(meta: model.meta, close: close)
        case .facts:
            PhoneFactsSheet(title: model.meta.name, facts: extras?.facts ?? [], close: close)
        case .awards(let group):
            PhoneAwardsSheet(group: group, entries: (awards?.entries ?? []).filter { $0.type == group.type }, close: close)
        case .tracker(let tracker):
            PhoneTrackerStatusSheet(tracker: tracker, onPick: { status in
                Task { await model.setTracker(tracker.key, status: status) }
            }, onRemove: {
                Task { await model.removeTracker(tracker.key) }
            }, close: close)
        case .trackers:
            PhoneTrackersSheet(close: close)
        }
    }

    /// A rating, a list or a sign-in may have changed what the bar and the More menu show.
    private func dialogClosed() {
        Task {
            await model.loadHero()
            await model.loadTrackers()
        }
    }

    // MARK: header

    /// The backdrop stretches with an overscroll and scrolls away under the bar.
    private var header: some View {
        GeometryReader { geo in
            // The stretch is parallax: under Reduce Motion the backdrop scrolls with the page instead.
            let pull = PhoneMotion.reduced ? 0 : max(0, geo.frame(in: .scrollView).minY)
            PhoneImage(url: model.meta.background ?? model.meta.poster)
                .frame(width: geo.size.width, height: geo.size.height + pull)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: BP.canvas.opacity(0.45), location: 0),
                        .init(color: .clear, location: 0.28),
                        .init(color: BP.canvas.opacity(0.55), location: 0.62),
                        .init(color: BP.canvas, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                .offset(y: -pull)
        }
        .frame(height: Self.headerHeight)
        .overlay(alignment: .bottom) { titleBlock }
    }

    private var titleBlock: some View {
        VStack(spacing: 10) {
            Group {
                if let logo = model.meta.logo, !logo.isEmpty {
                    PhoneImage(url: logo, contentMode: .fit, plate: false)
                        .frame(width: 260, height: 96)
                } else {
                    Text(verbatim: model.meta.name)
                        .font(PhoneTheme.display(34, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(BP.ink)
                        .multilineTextAlignment(.center)
                        .lines(3)
                        .minimumScaleFactor(0.7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: model.meta.name))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("detail-name")
            if !factsLine.isEmpty {
                Text(verbatim: factsLine)
                    .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundStyle(BP.inkMuted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("detail-facts")
            }
            // bp-hero-notes BpHeroMarks: the home servers whose index holds this title.
            if let server = model.titleServers.first {
                Label(T("Available in %@", server.name), systemImage: "externaldrive.connected.to.line.below")
                    .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(BP.inkSubtle)
            }
        }
        .padding(.horizontal, PhoneTheme.margin + 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    /// bpFacts ("2024 · 2h 46m · Science Fiction, Adventure") and the IMDb rating.
    private var factsLine: String {
        var parts: [String] = []
        let facts = model.meta.facts
        if !facts.isEmpty { parts.append(facts) }
        if let r = model.meta.imdbRating, !r.isEmpty { parts.append("IMDb \(r)") }
        return parts.joined(separator: " · ")
    }

    // MARK: actions

    private var actionBar: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    Button(action: play) {
                        Label(model.playLabel, systemImage: "play.fill")
                            .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                            .foregroundStyle(BP.on)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(BP.accent)
                    .accessibilityIdentifier("detail-play")
                    HStack(spacing: 8) {
                        let saved = model.inWatchlist
                        actionButton(T("Watchlist"), systemImage: saved ? "checkmark" : "plus",
                                     label: saved ? T("In Watchlist") : T("Add to Watchlist"), id: "detail-watchlist", active: saved) {
                            toggleWatchlist()
                        }
                        let score = model.hero?.rating
                        actionButton(T("Rate"), systemImage: score == nil ? "star" : "star.fill",
                                     label: score.map { T("Your rating %lld/10", $0) } ?? T("Rate this"), id: "detail-rate", active: score != nil) {
                            dialog = .rate
                        }
                        if let yt = trailerYtId {
                            actionButton(T("Trailer"), systemImage: "play.rectangle", label: T("Watch trailer"), id: "detail-trailer") {
                                dialog = .trailer(ytId: yt, name: nil)
                            }
                        }
                        shareButton
                        moreMenu
                    }
                }
            }
            if let r = model.resume, model.resumeIsPlayTarget, r.progress > 0.01 {
                ProgressView(value: r.progress)
                    .tint(BP.accent)
                    .accessibilityIdentifier("detail-resume-progress")
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-actions")
    }

    private func actionButton(_ caption: String, systemImage: String, label: String, id: String, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PhoneActionCell(caption: caption, systemImage: systemImage, active: active)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier(id)
    }

    /// The IMDb page when the title has an IMDb id, else its name.
    @ViewBuilder private var shareButton: some View {
        let cell = PhoneActionCell(caption: T("Share"), systemImage: "square.and.arrow.up")
        Group {
            if let id = model.imdbId, let url = URL(string: "https://www.imdb.com/title/\(id)/") {
                ShareLink(item: url, subject: Text(verbatim: model.meta.name)) { cell }
            } else {
                ShareLink(item: model.meta.name) { cell }
            }
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(verbatim: T("Share")))
        .accessibilityIdentifier("detail-share")
    }

    private struct MoreAction: Identifiable {
        let key: String
        let label: String
        let icon: String
        let run: () -> Void
        var id: String { key }
    }

    /// use-bp-detail-actions in its order, less the bar's own (Watchlist, Rate, Trailer).
    private var moreActions: [MoreAction] {
        var out: [MoreAction] = []
        let hero = model.hero
        if model.isMovie, SettingsBridge.shared.slice.instantPlay ?? true {
            out.append(MoreAction(key: "sources", label: T("Sources"), icon: "list.bullet") {
                PhonePlay.request(meta: model.meta, video: nil, auto: false, detail: model)
            })
        }
        for tr in model.trackers {
            let label = tr.statusLabel.map { "\(tr.name) · \(T($0))" } ?? T("Add to %@", tr.name)
            out.append(MoreAction(key: "tracker-\(tr.key)", label: label, icon: tr.status == nil ? "plus.circle" : "checkmark.circle") {
                dialog = .tracker(tr)
            })
        }
        if model.isMovie, hero?.traktMovie == true {
            out.append(MoreAction(key: "trakt", label: T("Mark watched on Trakt"), icon: "t.circle") {
                Task { await model.traktMarkWatched(); PhoneFeedback.shared.success() }
            })
        }
        let fav = hero?.favorite ?? false
        out.append(MoreAction(key: "favorite", label: fav ? T("Favorited") : T("Add to favorites"), icon: fav ? "heart.fill" : "heart") {
            PhoneFeedback.shared.selection()
            Task { await model.toggleFavorite() }
        })
        if model.isSeries {
            let on = hero?.reminder ?? false
            out.append(MoreAction(key: "reminder", label: on ? T("Reminder on") : T("Remind me"), icon: on ? "bell.fill" : "bell") {
                PhoneFeedback.shared.selection()
                Task { await model.toggleReminder() }
            })
        }
        out.append(MoreAction(key: "lists", label: T("Add to list"), icon: "square.stack.3d.up") { dialog = .lists })
        if let facts = extras?.facts, !facts.isEmpty {
            out.append(MoreAction(key: "facts", label: T("Details"), icon: "info.circle") { dialog = .facts })
        }
        // The tracker sign-ins (the TV keeps them in Settings; the phone has them a tap from a title).
        out.append(MoreAction(key: "trackers", label: T("Trackers"), icon: "person.crop.circle.badge.checkmark") { dialog = .trackers })
        if model.resume != nil {
            out.append(MoreAction(key: "cw-remove", label: T("Remove from Continue watching"), icon: "xmark.circle") {
                Task { if await model.removeFromContinueWatching() { PhoneFeedback.shared.success() } }
            })
        }
        if model.isMovie, hero?.showWatchedButton ?? true {
            let watched = model.movieWatched
            out.append(MoreAction(key: "watched", label: watched ? T("Marked watched") : T("Mark watched"), icon: watched ? "eye.fill" : "eye") {
                PhoneFeedback.shared.selection()
                Task { await model.toggleWatched() }
            })
        }
        return out
    }

    private var moreMenu: some View {
        Menu {
            ForEach(moreActions) { a in
                Button(a.label, systemImage: a.icon, action: a.run)
                    .accessibilityIdentifier("more-\(a.key)")
            }
        } label: {
            PhoneActionCell(caption: T("More"), systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .accessibilityLabel(Text(verbatim: T("More")))
        .accessibilityIdentifier("detail-more")
    }

    private func toggleWatchlist() {
        guard !model.watchlistBusy else { return }
        PhoneFeedback.shared.selection()
        Task {
            await model.toggleWatchlist()
            PhoneToaster.shared.show(model.inWatchlist ? T("Added to Watchlist") : T("Removed from Watchlist"))
        }
    }

    /// Play / Resume: a series plays its play target (the resume point, the hinted episode, else the
    /// season's first), or the premiere when no episode resolved; a film plays itself.
    private func play() {
        hintSpent = true
        let video: AnyJSON? = model.isSeries ? (model.playTarget?.playEpisode ?? model.premiereEpisode) : nil
        PhonePlay.request(meta: model.meta, video: video, detail: model)
    }

    private func play(_ ep: DetailModel.Episode) {
        hintSpent = true
        PhonePlay.request(meta: model.meta, video: ep.playEpisode, detail: model)
    }

    // MARK: synopsis

    private var overview: String {
        let o = extras?.overview ?? ""
        return o.isEmpty ? (model.meta.description ?? "") : o
    }

    @ViewBuilder private var synopsis: some View {
        let tagline = extras?.tagline ?? ""
        let text = overview
        if !tagline.isEmpty || !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !tagline.isEmpty {
                    Text(verbatim: tagline)
                        .font(PhoneTheme.display(17, .medium, relativeTo: .headline))
                        .italic()
                        .foregroundStyle(BP.ink)
                }
                if !text.isEmpty {
                    Text(verbatim: text)
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .body))
                        .foregroundStyle(BP.inkMuted)
                        .lineSpacing(2)
                        .lineLimit(synopsisOpen ? nil : 4)
                        .accessibilityIdentifier("detail-synopsis")
                    if text.count > 200 {
                        Button(synopsisOpen ? T("Show less") : T("Read more")) {
                            withMotion(.easeInOut(duration: 0.25)) { synopsisOpen.toggle() }
                        }
                        .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(BP.accent)
                        .accessibilityIdentifier("detail-synopsis-more")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PhoneTheme.margin)
        }
    }

    // MARK: episodes

    private func seasonName(_ s: Int) -> String { s == 0 ? T("Specials") : T("Season %lld", s) }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: T("Episodes"))
                    .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                seasonMenu
                seasonOptions
            }
            .padding(.horizontal, PhoneTheme.margin)
            LazyVStack(spacing: 8) {
                ForEach(model.seasonEpisodes) { ep in
                    episodeRow(ep).id(Self.rowId(ep.season, ep.episode))
                }
            }
            .padding(.horizontal, PhoneTheme.margin - 8)
        }
    }

    private func seasonMenuLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title).lines(1)
            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
        }
        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
        .foregroundStyle(BP.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// The season Menu (the TV's SeasonsSheet); an anime with TVDB chips lists them instead.
    @ViewBuilder private var seasonMenu: some View {
        if !model.animeChips.isEmpty {
            let current = model.animeChips.first { $0.key == model.animeSeasonKey }?.name ?? T("Seasons")
            Menu {
                ForEach(model.animeChips) { chip in
                    Button {
                        PhoneFeedback.shared.selection()
                        model.selectAnimeSeason(chip.key)
                    } label: {
                        if chip.key == model.animeSeasonKey {
                            Label(chip.name, systemImage: "checkmark")
                        } else {
                            Text(verbatim: chip.name)
                        }
                    }
                }
            } label: {
                seasonMenuLabel(current)
            }
            .accessibilityLabel(Text(verbatim: current))
            .accessibilityIdentifier("detail-season-menu")
        } else if model.seasons.count > 1 {
            Menu {
                ForEach(model.seasons, id: \.self) { s in
                    Button {
                        PhoneFeedback.shared.selection()
                        model.pickKitsuSeason(s)
                    } label: {
                        if s == model.season {
                            Label(seasonName(s), systemImage: "checkmark")
                        } else {
                            Text(verbatim: seasonName(s))
                        }
                    }
                    .accessibilityIdentifier("season-\(s)")
                }
            } label: {
                seasonMenuLabel(seasonName(model.season))
            }
            .accessibilityLabel(Text(verbatim: seasonName(model.season)))
            .accessibilityIdentifier("detail-season-menu")
        } else if let s = model.seasons.first {
            Text(verbatim: seasonName(s))
                .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                .foregroundStyle(BP.inkMuted)
                .accessibilityIdentifier("detail-season-menu")
        }
    }

    /// episode-grid-controls OptionsMenu: the season's watched marks.
    private var seasonOptions: some View {
        Menu {
            let all = model.seasonAllWatched
            Button(all ? T("Mark season as unwatched") : T("Mark season as watched"), systemImage: all ? "eye.slash" : "checkmark.circle") {
                guard let ep = model.seasonEpisodes.first else { return }
                PhoneFeedback.shared.success()
                Task { await model.markWatched(ep, .season, watched: !all) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BP.ink)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel(Text(verbatim: T("More")))
        .accessibilityIdentifier("detail-season-options")
    }

    private func episodeRow(_ ep: DetailModel.Episode) -> some View {
        let watched = model.isWatched(ep)
        return PhoneEpisodeRow(
            episode: ep,
            watched: watched,
            fact: model.fact(for: ep),
            still: model.stillChain(for: ep).first,
            spoiler: model.spoilerMask(for: ep),
            showRating: model.showEpisodeRating,
            showDescription: model.showEpisodeDescription,
            progress: model.progress(for: ep),
            highlighted: highlighted.map { $0.season == ep.season && $0.episode == ep.episode } ?? false
        ) {
            play(ep)
        }
        .contextMenu {
            Button(T("Play"), systemImage: "play.fill") { play(ep) }
            episodeWatchedMenu(ep, watched: watched)
        }
    }

    /// The TV's episodeWatchedMenu: a watched episode can be unmarked; an unwatched one marked, marked
    /// with every one before it, or (once started) cleared of its progress; then the whole season.
    @ViewBuilder private func episodeWatchedMenu(_ ep: DetailModel.Episode, watched: Bool) -> some View {
        if watched {
            mark(T("Mark as unwatched"), "eye.slash") { await model.markWatched(ep, .episode, watched: false) }
        } else {
            mark(T("Mark as watched"), "checkmark") { await model.markWatched(ep, .episode, watched: true) }
            mark(T("Mark watched up to here"), "eye") { await model.markWatched(ep, .upTo, watched: true) }
            if model.isStarted(ep) {
                mark(T("Mark as unwatched"), "eye.slash") { await model.markWatched(ep, .episode, watched: false) }
            }
        }
        if model.seasonAllWatched {
            mark(T("Mark season as unwatched"), "eye.slash") { await model.markWatched(ep, .season, watched: false) }
        } else {
            mark(T("Mark season as watched"), "checkmark.circle") { await model.markWatched(ep, .season, watched: true) }
        }
    }

    private func mark(_ title: String, _ icon: String, _ run: @escaping () async -> Void) -> some View {
        Button(title, systemImage: icon) {
            PhoneFeedback.shared.success()
            Task { await run() }
        }
    }

    // MARK: awards, details, people, related

    /// The facts sheet; the gallery has its own rail further down.
    @ViewBuilder private var linksRow: some View {
        if let facts = extras?.facts, !facts.isEmpty {
            ChipRow {
                GlassChip(title: T("Details"), systemImage: "info.circle") { dialog = .facts }
            }
        }
    }

    /// bp-gallery-row shows for a TMDB title (an anime id has no TMDB gallery).
    private var showGallery: Bool {
        !model.isAnimeId && (!SettingsBridge.shared.slice.tmdbKey.isEmpty || PhoneDetailFixtures.active)
    }

    /// bp-videos-row: 16:9 YouTube thumbnails, kind over name; a tap plays the clip in the trailer sheet.
    @ViewBuilder private var videosRail: some View {
        if let clips = extras?.videos, !clips.isEmpty {
            Rail(T("Videos"), identifier: "videos") {
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                    // The engine's unnamed extra trailers are numbered within the row.
                    let name = c.name == "Trailer" ? "\(T("Trailer")) \(clips.prefix(i + 1).filter { $0.name == "Trailer" }.count)" : c.name
                    Button {
                        PhoneFeedback.shared.tap()
                        dialog = .trailer(ytId: c.ytId, name: name)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                PhoneImage(url: "https://img.youtube.com/vi/\(c.ytId)/mqdefault.jpg")
                                Image(systemName: "play.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .glassEffect(.regular, in: .circle)
                            }
                            .frame(width: 232, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
                            Text(verbatim: T(c.type))
                                .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                                .textCase(.uppercase)
                                .tracking(1)
                                .foregroundStyle(BP.inkSubtle)
                                .lines(1)
                            Text(verbatim: name)
                                .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(BP.ink)
                                .lines(1)
                        }
                        .frame(width: 232, alignment: .leading)
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: name))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("video-\(i)")
                }
            }
        }
    }

    private func awardCounts(_ g: DetailModel.TitleAwards.Group) -> String {
        var parts: [String] = []
        if g.wins > 0 { parts.append(TCount(g.wins, one: "%lld win", "%lld wins")) }
        if g.nominations > 0 { parts.append(TCount(g.nominations, one: "%lld nom", "%lld noms")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var awardsRow: some View {
        if let groups = awards?.groups, !groups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: T("Awards & Recognition"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(groups) { g in
                            Button {
                                dialog = .awards(g)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(g.title, systemImage: "trophy")
                                        .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                                        .foregroundStyle(BP.ink)
                                        .lines(1)
                                    Text(verbatim: awardCounts(g))
                                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                                        .foregroundStyle(BP.inkMuted)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .phoneGlassPlate()
                            }
                            .buttonStyle(PressScaleStyle())
                            .accessibilityIdentifier("detail-award-\(g.type)")
                        }
                    }
                    .padding(.horizontal, PhoneTheme.margin)
                }
            }
        }
    }

    @ViewBuilder private var castRail: some View {
        if let cast = extras?.cast, !cast.isEmpty {
            Rail(T("Cast"), identifier: "cast") {
                ForEach(cast.prefix(24)) { c in
                    Button {
                        nav.push(PhoneRoute.person(id: c.id, name: c.name))
                    } label: {
                        PhonePersonCell(name: c.name, detail: c.character, photo: c.profile)
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: c.character.isEmpty ? c.name : "\(c.name), \(c.character)"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("cast-\(c.id)")
                }
            }
        }
    }

    /// bp-crew-row: Directed by / Created by / Written by …
    @ViewBuilder private var crewLines: some View {
        if let crew = extras?.crew, !crew.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(crew.prefix(4)) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: T(c.label))
                            .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(BP.inkSubtle)
                            .frame(width: 104, alignment: .leading)
                        Text(verbatim: c.names.joined(separator: ", "))
                            .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                            .foregroundStyle(BP.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
        }
    }

    /// bp-anime-characters: AniList's characters for an anime id.
    @ViewBuilder private var charactersRail: some View {
        if !model.characters.isEmpty {
            Rail(T("Characters"), identifier: "characters") {
                ForEach(model.characters.prefix(24)) { c in
                    PhonePersonCell(name: c.name, detail: c.role ?? "", photo: c.image)
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private var relatedRails: some View {
        if let row = model.collectionRow, !row.metas.isEmpty {
            posterRail(row.title, key: "collection", metas: row.metas)
        }
        if let x = extras {
            if !x.recommendations.isEmpty { posterRail(T("More Like This"), key: "recommendations", metas: x.recommendations) }
            if !x.similar.isEmpty { posterRail(T("You Might Also Like"), key: "similar", metas: x.similar) }
        }
    }

    private func posterRail(_ title: String, key: String, metas: [Meta]) -> some View {
        Rail(title, identifier: key) {
            ForEach(metas) { m in
                PosterTile(meta: m) { nav.open(m) }
                    .phoneContextMenu(for: m, open: { nav.open($0) })
            }
        }
    }

    /// The TV's note when TMDB has nothing to give without a key.
    @ViewBuilder private var tmdbNote: some View {
        if model.loadStage == .library, extras == nil, !model.isAnimeId, SettingsBridge.shared.slice.tmdbKey.isEmpty {
            Text(verbatim: T("Add a TMDB key in Settings to see the cast, crew, and details."))
                .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                .foregroundStyle(BP.inkSubtle)
                .padding(.horizontal, PhoneTheme.margin)
        }
    }

    // MARK: bar

    /// The scroll view runs under the bar for the backdrop, which leaves the system's scroll edge
    /// effect nothing to work with: once the header has gone, a canvas fade sits behind the bar
    /// instead, so the title and the back button don't read over the Play button and the facts line
    /// scrolling past. The overlay's top is the bar's bottom edge; the fade reaches up under the bar
    /// to the screen edge and runs a little past it.
    private var barShade: some View {
        Color.clear
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(stops: [
                    .init(color: BP.canvas, location: 0),
                    .init(color: BP.canvas.opacity(0.92), location: 0.62),
                    .init(color: BP.canvas.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
            }
            .opacity(scrolledPast ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(verbatim: model.meta.name)
                .font(PhoneTheme.sans(16, .semibold, relativeTo: .headline))
                .foregroundStyle(BP.ink)
                .lines(1)
                .opacity(scrolledPast ? 1 : 0)
                .accessibilityHidden(!scrolledPast)
        }
        if let close {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(Text(verbatim: T("Close")))
                .accessibilityIdentifier("detail-close")
            }
        }
    }
}

/// An action bar cell: the icon over a short caption.
private struct PhoneActionCell: View {
    let caption: String
    let systemImage: String
    var active = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(height: 22)
            Text(verbatim: caption)
                .font(PhoneTheme.sans(11, .semibold, relativeTo: .caption2))
                .lines(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(active ? BP.accent : BP.ink)
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// A cast member or character: the round photo, the name and the role.
private struct PhonePersonCell: View {
    let name: String
    let detail: String
    let photo: String?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                PhoneImage(url: photo)
                if photo == nil {
                    Image(systemName: "person.fill")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(BP.inkSubtle)
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(Circle())
            Text(verbatim: name)
                .font(PhoneTheme.sans(13, .semibold, relativeTo: .caption))
                .foregroundStyle(BP.ink)
                .lines(2)
                .multilineTextAlignment(.center)
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(PhoneTheme.sans(12, .regular, relativeTo: .caption2))
                    .foregroundStyle(BP.inkMuted)
                    .lines(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 96, alignment: .top)
    }
}

/// A harbor://detail link (and the Resume strip's title): the title page in a sheet over the tabs,
/// with its own navigation stack (the cast and related titles push inside it) and play host. It
/// reports itself to the deep-link queue as the old stub did: `presentedCover("title")` holds the
/// next link back while it is up, and its appearance tells AppModel the link landed.
struct PhoneDetailSheet: View {
    static let presenceId = "title"

    let close: () -> Void
    @EnvironmentObject private var app: AppModel
    /// Made once: the sheet's body runs again on every change above it.
    @State private var target: PhoneDetailTarget

    init(meta: Meta, close: @escaping () -> Void) {
        self.close = close
        // A Continue Watching resume waiting for this title: the page plays at once, on its episode.
        // Read, not taken: SwiftUI may build this view more than once before the sheet is up.
        let resume = PhonePlay.shared.waitingResume(for: meta.id)
        _target = State(initialValue: PhoneDetailTarget(meta: meta, hint: resume.hint, autoPlay: resume.play))
    }

    var body: some View {
        PhoneTabStack { _ in
            PhoneDetailView(target: target, close: close)
        }
        .phonePlayHost(inCover: true)
        .presentationDetents([.large])
        .presentedCover(Self.presenceId)
        .onAppear {
            app.deepLinkCoverAppeared()
            PhonePlay.shared.resumeShown(for: target.meta.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-sheet")
    }
}
