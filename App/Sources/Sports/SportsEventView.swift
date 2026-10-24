import SwiftUI


struct SportsEventView: View {
    let game: SportsModel.Game
    let dismiss: () -> Void
    /// bp-sports-watch openSetup (goBigPictureTab("live")): closes the event and opens Live TV.
    var openLive: (() -> Void)? = nil
    @StateObject private var model = SportsEventModel()
    @State private var playing: SportsEventModel.WatchOption?
    @State private var picker = false
    struct WhoTarget: Identifiable { let id: String }   // "home" | "away"
    @State private var who: WhoTarget?
    /// bp-sports-addon-panel: open on the listings (row nil) or straight on one listing's streams.
    struct AddonOpen: Identifiable { let row: SportsEventModel.AddonRow?; var id: String { row?.key ?? "listings" } }
    @State private var addonPanel: AddonOpen?
    @State private var addonPlaying: SportsAddonPanelView.Play?
    @State private var broadcastsOpen = false
    /// bp-sports-broadcast-search: "Search your channels" over every playlist.
    @State private var searchOpen = false
    @State private var link: SportsLink?
    @State private var webhookSetup = false
    /// bp-sports-broadcast-picker seeds the ring on its first entry (a
    /// broadcast, else a channel match, else an action) and puts it back where it was when it closes.
    /// The inline picker opened below its button with the ring left on the button, and Menu (or a
    /// pick, once the player handed back) removed the rows under the ring, which fell to wherever
    /// the focus engine chose. "opener" is the button that toggles the picker.
    @FocusState private var pickSeat: String?
    @State private var pickerReturn = false

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(20)) {
                    hero
                    watchSection
                    heroNotes
                    if let s = model.rows?.stats { SportsStatsRowView(stats: s) }
                    if let l = model.rows?.lineups { SportsLineupsRowView(lineups: l) }
                    if model.rows == nil && model.loading { ProgressView().tint(BP.inkMuted) }
                    StandingsSection(league: game.league, highlight: [game.home.id, game.away.id])
                    addonRow
                    SportsWhereRowView(game: game)
                    Button("Go back") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight + BP.px(40))
            }
        }
        .task { await model.loadOnce(game) }
        .task { await model.loadWhoSides(game) }
        .task { await model.loadActions(game) }
        .task { await model.loadAddonsOnce(game) }
        .task { if game.state != "post" { await model.resolveWatch(game) } }
        .task {
            // use-match-detail: a game in progress refreshes its summary every 30 s.
            guard game.state == "in" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await model.refresh(game)
            }
        }
        .onExitCommand {
            guard picker else { dismiss(); return }
            let inPicker: Bool = pickSeat != nil
            picker = false
            if inPicker { DispatchQueue.main.async { pickSeat = "opener" } }
        }
        .onChange(of: picker) { _, open in
            guard open, let w = model.watch, let seed = Self.pickerSeed(w) else { return }
            DispatchQueue.main.async { pickSeat = seed }
        }
        .fullScreenCover(item: $playing, onDismiss: {
            guard pickerReturn else { return }
            pickerReturn = false
            DispatchQueue.main.async { pickSeat = "opener" }
        }) { opt in
            PlayerScreen(title: opt.name, subtitle: model.watch?.fixture ?? game.leagueLabel, url: URL(string: opt.url) ?? URL(string: "about:blank")!, headers: opt.headers ?? [:], isLive: true) { _ in playing = nil }
        }
        .fullScreenCover(item: $who) { t in SportsWhoView(game: game, side: t.id) }
        .fullScreenCover(item: $addonPanel) { open in
            SportsAddonPanelView(game: game, model: model, initial: open.row, onPlay: { play in
                addonPanel = nil
                // Present after the panel's cover has dismissed; a present-while-dismissing is dropped on tvOS.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { addonPlaying = play }
            }, onClose: { addonPanel = nil })
        }
        .fullScreenCover(item: $addonPlaying) { p in
            PlayerScreen(title: p.title, subtitle: p.subtitle, url: p.url, headers: p.headers, isLive: p.isLive, streamSubtitles: p.subtitles) { _ in addonPlaying = nil }
        }
        .fullScreenCover(isPresented: $broadcastsOpen) {
            SportsBroadcastsView(
                fixture: model.watch?.fixture ?? game.headline,
                broadcasts: model.watch?.broadcasts ?? [],
                onAir: model.watch?.onAir ?? false,
                channels: broadcastChannelsAction,
                addons: broadcastAddonsAction,
                setup: broadcastSetupAction,
                onClose: { broadcastsOpen = false })
        }
        .fullScreenCover(item: $link) { l in SportsLinkView(link: l) { link = nil } }
        .fullScreenCover(isPresented: $searchOpen, onDismiss: { Task { await model.resolveWatch(game) } }) {
            SportsChannelSearchView(game: game, onPlay: { opt in
                // BpSportsBroadcastSearch onPlay: setSearching(false), then playSearched. Present
                // after this cover has gone; a present-while-dismissing is dropped on tvOS.
                searchOpen = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { play(opt) }
            }, onClose: { searchOpen = false })
        }
        .fullScreenCover(isPresented: $webhookSetup) {
            ZStack {
                BP.void_.opacity(0.94).ignoresSafeArea()
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text("Set up reminders").font(BP.display(30)).foregroundStyle(BP.ink)
                    SportsWebhooksPanel(onDone: {
                        webhookSetup = false
                        Task { await model.loadActions(game) }
                    })
                }
                .frame(maxWidth: BP.px(1100), alignment: .leading)
                .padding(BP.gutter)
            }
            .onExitCommand { webhookSetup = false; Task { await model.loadActions(game) } }
        }
    }

    // bp-sports-watch.tsx press, per plan, plus the hero's secondary actions.
    @ViewBuilder private var watchSection: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(10)) {
                if game.state != "post", let w = model.watch {
                    primary(w)
                    // bp-sports-event heroActions: "Choose a channel" when there is more than one pick.
                    if (w.plan == "stream" || w.plan == "broadcast") && !w.channels.isEmpty {
                        Button("Choose a channel") { picker.toggle() }.buttonStyle(BPActionStyle())
                            .focused($pickSeat, equals: "opener")
                    }
                    if w.plan == "channel" && w.channels.count > 1 {
                        Button("Other channels") { picker.toggle() }.buttonStyle(BPActionStyle())
                            .focused($pickSeat, equals: "opener")
                    }
                    if w.plan != "addons" && (model.addons?.available ?? 0) > 0 {
                        Button("Addon sources") { addonPanel = AddonOpen(row: nil) }.buttonStyle(BPActionStyle())
                    }
                } else if game.state != "post" && model.watching {
                    ProgressView().tint(BP.inkMuted)
                    Text("Checking your channels…").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                }
                // bp-sports-event canRetry (failed && summary): "Match details are
                // not available" had no way to ask again short of leaving the page.
                if model.failed && summarySource {
                    Button {
                        guard !model.loading else { return }
                        Task { await model.load(game) }
                    } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(BPActionStyle(busy: model.loading))
                }
                heroActions
            }
            if game.state != "post", let w = model.watch {
                if w.plan == "setup" { Text("Add a Live TV source to watch matches here.").font(BP.sans(13)).foregroundStyle(BP.inkMuted) }
                if picker || (w.plan == "picker" && w.channels.isEmpty) { channelPicker(w) }
            }
        }
        .focusSection()
    }

    @ViewBuilder private func primary(_ w: SportsEventModel.Watch) -> some View {
        switch w.plan {
        case "stream":
            Button(w.label.map { T($0) } ?? T("Watch")) { playAttached(w) }.buttonStyle(BPActionStyle(primary: true))
        case "broadcast":
            Button(w.label.map { T($0) } ?? T("Where to watch")) {
                // setAuto(pickCount > 1 ? null : shows[0]): a single broadcast opens straight away.
                if w.broadcasts.count == 1 && w.channels.isEmpty, let b = w.broadcasts.first { link = broadcastLink(b) } else { broadcastsOpen = true }
            }
            .buttonStyle(BPActionStyle(primary: true))
        case "channel":
            if let first = w.channels.first { Button((w.label.map { T($0) } ?? T("Watch")) + " · " + first.name) { play(first) }.buttonStyle(BPActionStyle(primary: true)) }
        case "picker":
            // With no match the button's own copy promises the search, so it opens it when it can.
            Button(w.channels.isEmpty ? T("Search your channels") : w.channels.count == 1 ? T("Watch · 1 channel found") : T("Watch · %lld channels found", w.channels.count)) {
                if w.channels.isEmpty && w.searchable == true { searchOpen = true } else { picker.toggle() }
            }
            .buttonStyle(BPActionStyle(primary: true))
            .focused($pickSeat, equals: "opener")
        case "addons":
            Button("Addon sources") { addonPanel = AddonOpen(row: nil) }.buttonStyle(BPActionStyle(primary: true))
        case "setup":
            // bp-sports-watch press on "setup" opens Live TV; the plan drew no
            // button at all, so the page offered nothing to do about "Add a Live TV source".
            if let openLive { Button(T("Set up Live TV")) { openLive() }.buttonStyle(BPActionStyle(primary: true)) }
        default:
            EmptyView()
        }
    }

    // useBpSportsEventActions: the reminder bell, follow toggles, OpenDota's match page.
    @ViewBuilder private var heroActions: some View {
        if let a = model.actions {
            if let r = a.reminder {
                Button {
                    Task {
                        if await model.toggleReminder(game) == "setup" { webhookSetup = true }
                    }
                } label: { Label(r.label, systemImage: r.active ? "bell.and.waves.left.and.right.fill" : "bell") }
                .buttonStyle(BPActionStyle(primary: r.active))
                .bpSelected(r.active)
            }
            ForEach(a.follow) { f in
                Button { Task { await model.toggleFollow(game, f.key) } } label: { Label(f.label, systemImage: f.on ? "heart.fill" : "heart") }
                    .buttonStyle(BPActionStyle(primary: f.on))
                    .bpSelected(f.on)
            }
            if let url = a.opendota {
                Button { link = SportsLink(title: T("View match statistics"), url: url) } label: { Label("View match statistics", systemImage: "arrow.up.right.square") }
                    .buttonStyle(BPActionStyle())
            }
        }
    }

    // bp-sports-broadcast-picker: official broadcasts first, then channel matches with their tier copy.
    @ViewBuilder private func channelPicker(_ w: SportsEventModel.Watch) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ForEach(w.broadcasts) { b in
                Button { link = broadcastLink(b) } label: {
                    HStack(spacing: BP.px(10)) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(BP.inkMuted).frame(width: BP.px(48)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            Text(T(b.platformLabel)).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BPActionStyle())
                .focused($pickSeat, equals: "b:" + b.id)
            }
            ForEach(w.channels) { opt in
                HStack(spacing: BP.px(8)) {
                    Button { play(opt) } label: {
                        HStack(spacing: BP.px(10)) {
                            RemoteImage(url: opt.logo, contentMode: .fit).frame(width: BP.px(48), height: BP.px(28))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.label).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(Self.matchLine(opt)).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                            }
                            Spacer()
                            Text(opt.tier.capitalized).font(BP.sans(11, .bold)).foregroundStyle(opt.tier == "exact" ? BP.live : BP.inkSubtle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BPActionStyle())
                    .focused($pickSeat, equals: "c:" + opt.channelId)
                    Button(opt.attached ? T("Unpin") : T("Always use for %@", game.leagueLabel)) { Task { await model.togglePin(game, opt) } }.buttonStyle(BPActionStyle(primary: opt.attached))
                        .focused($pickSeat, equals: "p:" + opt.channelId)
                }
            }
            if w.channels.isEmpty {
                Text(w.sources == 0 ? T("No playlists yet. Add one in Live TV and Harbor will match its channels to fixtures.")
                     : T("None of your channels match this fixture. Search your channels and pin the one that carries it.") + " (\(w.scanned) sports channels scanned)")
                    .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            // bp-sports-broadcast-picker action row: Search your channels (canSearch), Addon sources
            // (onAddons: an addon has any listing), Set up Live TV (onSetup).
            HStack(spacing: BP.px(10)) {
                if w.searchable == true {
                    Button { searchOpen = true } label: { Label("Search your channels", systemImage: "magnifyingglass") }.buttonStyle(BPActionStyle())
                        .focused($pickSeat, equals: "search")
                }
                if (model.addons?.available ?? 0) > 0 {
                    Button("Addon sources") { addonPanel = AddonOpen(row: nil) }.buttonStyle(BPActionStyle())
                        .focused($pickSeat, equals: "addons")
                }
                if let openLive {
                    Button(T("Set up Live TV")) { openLive() }.buttonStyle(BPActionStyle())
                        .focused($pickSeat, equals: "setup")
                }
            }
            // attachedIds.length > 0: the pinned-channel note under the actions.
            if let pins = w.attachedIds, !pins.isEmpty {
                Label(T("Pinned channels are tried first for %@.", w.leagueLabel ?? game.leagueLabel), systemImage: "pin")
                    .font(BP.sans(12, .semibold)).foregroundStyle(BP.inkSubtle)
            }
        }
        .frame(maxWidth: BP.px(900), alignment: .leading)
    }

    // bp-sports-broadcast-picker action chips: "Search your channels" (Live TV sources exist) and "Addon sources".
    private var broadcastChannelsAction: (() -> Void)? {
        guard model.watch?.searchable == true else { return nil }
        return {
            broadcastsOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { searchOpen = true }
        }
    }
    private var broadcastAddonsAction: (() -> Void)? {
        guard (model.addons?.available ?? 0) > 0 else { return nil }
        return {
            broadcastsOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { addonPanel = AddonOpen(row: nil) }
        }
    }

    /// bp-sports-broadcast-picker "Set up Live TV" (onSetup): the list closes with the event.
    private var broadcastSetupAction: (() -> Void)? {
        guard let openLive else { return nil }
        return {
            broadcastsOpen = false
            openLive()
        }
    }

    private func broadcastLink(_ b: SportsEventModel.Broadcast) -> SportsLink {
        SportsLink(title: b.title, url: b.url, app: b.app, message: T("Official broadcast. It plays in the %@ app, or scan to watch on your phone.", b.platformLabel))
    }

    /// The channel-match line: its copy, then up to two reasons (split out of the view body for the type checker).
    private static func matchLine(_ opt: SportsEventModel.WatchOption) -> String {
        let copy: String = T(opt.copy)
        guard !opt.reasons.isEmpty else { return copy }
        let reasons: [String] = opt.reasons.prefix(2).map { T($0) }
        return copy + " · " + reasons.joined(separator: ", ")
    }

    /// bp-sports-broadcast-picker seedAt: the first broadcast, else the first channel match, else
    /// the first action (Search your channels).
    private static func pickerSeed(_ w: SportsEventModel.Watch) -> String? {
        if let b = w.broadcasts.first { return "b:" + b.id }
        if let c = w.channels.first { return "c:" + c.channelId }
        return w.searchable == true ? "search" : nil
    }

    private func play(_ opt: SportsEventModel.WatchOption) {
        // bp-sports-watch pick: setPicking(false) — the list is closed when the player hands back,
        // and the ring goes back to the button that opened it (the picker's focus restore).
        if picker { pickerReturn = true }
        picker = false
        model.recordPlay(opt, game: game)
        playing = opt
    }

    // useBpSportsPlayStream: the attached stream plays live unless it is a file; subtitle is the page host.
    private func playAttached(_ w: SportsEventModel.Watch) {
        guard let s = w.attachedStream, let url = URL(string: s.url) else { return }
        let host = URL(string: s.page)?.host
        addonPlaying = SportsAddonPanelView.Play(url: url, headers: s.headers ?? [:], title: w.fixture, subtitle: host, isLive: s.kind != "file")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(8)) {
                RemoteImage(url: game.leagueLogo.isEmpty ? nil : game.leagueLogo, contentMode: .fit).frame(width: BP.px(24), height: BP.px(24))
                Text(game.leagueLabel).font(BP.sans(14, .semibold)).foregroundStyle(BP.inkMuted)
                if game.live { pill("Live", BP.live) } else if game.state == "post" { pill("Final", BP.inkMuted) }
                if saved { pill("Saved", BP.inkSubtle) }
            }
            if game.single || game.faceOff {
                Text(game.headline).font(BP.display(36)).foregroundStyle(BP.ink)
            } else {
                if let c = game.context, !c.name.isEmpty { Text(c.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted) }
                HStack(spacing: BP.px(24)) {
                    side(game.away, key: "away", opens: model.whoSides.away)
                    Text(scores ? "\(game.away.score.isEmpty ? "0" : game.away.score) : \(game.home.score.isEmpty ? "0" : game.home.score)" : "vs")
                        .font(BP.display(40)).foregroundStyle(BP.ink).monospacedDigit()
                    side(game.home, key: "home", opens: model.whoSides.home)
                }
            }
            Text(facts).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
        }
    }

    /// use-bp-sports-event `scores`: both sides named (not TBD / Winner of…),
    /// under way or over, and a score published. A postponed game read "0 : 0" as if played.
    private var scores: Bool {
        let unnamed: String = "^(tbd|tba|winner|loser)\\b"
        let named: (String) -> Bool = { name in
            !name.trimmingCharacters(in: .whitespaces).isEmpty && name.range(of: unnamed, options: [.regularExpression, .caseInsensitive]) == nil
        }
        let published: Bool = !game.home.score.isEmpty || !game.away.score.isEmpty
        return named(game.home.name) && named(game.away.name) && game.state != "pre" && published
    }

    private var facts: String {
        var parts: [String] = []
        if let c = game.context {
            if !c.round.isEmpty, !["standard", "std", "regular season"].contains(c.round.lowercased()) { parts.append(c.round) }
            if !c.venue.isEmpty { parts.append(c.venue) }
        }
        if !game.detail.isEmpty, game.state != "post" { parts.append(game.detail) }
        parts.append(game.startLabel)
        if let b = game.broadcasts, !b.isEmpty { parts.append(b.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// use-bp-sports-event SUMMARY_SOURCES: the feeds that have a match summary to read.
    private var summarySource: Bool { ["espn", "thesportsdb", "api-sports"].contains(game.source ?? "espn") }

    /// bp-sports-event-hero `saved`: a held summary the last read could not refresh, or a saved match.
    private var saved: Bool { model.held && ((model.failed && summarySource) || game.savedAt != nil) }

    /// bp-sports-event-hero `provenance`: where a promoter / ONE / TheSportsDB hub card comes from.
    private var provenance: String {
        let source: String = game.source ?? ""
        switch source {
        case "official-boxing":
            return "Schedule published by the event promoter. Visit the official fight card for the latest lineup and broadcast details."
        case "official-one":
            return "Schedule from ONE Championship. Visit the official event page for the announced fight card."
        case "thesportsdb-hub":
            return "Schedule from TheSportsDB. Live scores and detailed statistics are not supplied by this feed."
        default:
            return ""
        }
    }

    /// bp-sports-event-hero's notes under the actions (NOTE): loading, saved,
    /// the feed's provenance, and details not available. BPNote translates each key.
    @ViewBuilder private var heroNotes: some View {
        let unavailable: Bool = model.failed && summarySource && !model.held && !model.loading && provenance.isEmpty
        if model.loading && !model.held && summarySource { BPNote(text: "Loading match details...") }
        if saved { BPNote(text: "Showing saved match details.") }
        if !provenance.isEmpty && !model.held { BPNote(text: provenance) }
        if unavailable { BPNote(text: "Match details are not available right now. The scoreboard above is still live.") }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(T(text)).font(BP.sans(10, .bold)).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(Capsule().fill(color))
    }

    // bp-sports-addon-row: up to eight matching listings, then "Browse addon channels".
    @ViewBuilder private var addonRow: some View {
        if game.state != "post", let a = model.addons, a.available > 0 {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text("Addon sources").font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(10)) {
                        ForEach(model.matchingAddons.prefix(8)) { row in
                            Button { addonPanel = AddonOpen(row: row) } label: { SportsAddonTile(logo: row.addonLogo, title: row.name, sub: SportsAddonPanelView.matchCopy(row)) }
                                .buttonStyle(BPTileStyle(radius: BP.rMD))
                        }
                        Button { addonPanel = AddonOpen(row: nil) } label: {
                            SportsAddonTile(logo: nil, title: T("Browse addon channels"), sub: T("%lld listings from your addons", a.rows.count), icon: "powerplug")
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                    }
                    .padding(.vertical, BP.px(8))
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // bp-sports-event-hero BpEventSide: a side with a who subject is a button ("Open {name}") that
    // opens bp-sports-who-panel; otherwise it is plain.
    @ViewBuilder private func side(_ s: SportsModel.Side, key: String, opens: Bool) -> some View {
        let content = VStack(spacing: BP.px(6)) {
            RemoteImage(url: s.logo.isEmpty ? nil : s.logo, contentMode: .fit).frame(width: BP.px(72), height: BP.px(72))
            Text(s.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            let sub: String = ([s.rank.map { "#\($0)" }, s.record] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !sub.isEmpty { Text(sub).font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
        }
        .frame(width: BP.px(220)).padding(.vertical, BP.px(8))
        .accessibilityElement(children: .combine)
        if opens {
            Button { who = WhoTarget(id: key) } label: { content }
                .buttonStyle(BPTileStyle(radius: BP.rMD))
                // bp-sports-event-hero.tsx: aria-label={t("Open {name}", { name: side.name })}.
                .accessibilityLabel(T("Open %@", s.name))
        } else {
            content
        }
    }
}
