import SwiftUI

/// Stream picker: the ranked list grouped by quality tier, best cached pick first.
struct PlayPickerView: View {
    let meta: Meta
    let episode: AnyJSON?
    let onPlay: (ScoredStream?, StreamsModel.Resolved) -> Void
    /// use-bp-stream-play autoPlay: fire the best candidate once the pipeline settles (instantPlay).
    var autoPlay = false
    /// bp-streams.tsx applyPreference: this list opened from Play (not Sources or Switch source), so
    /// settings.playbackSourcePreference applies: only "online" fires on its own, and a home-server
    /// preference opens on the Media servers list and plays the preferred server's copy.
    var applyPreference = false
    /// bp-player-sources.tsx BpPlayerSources → `<BpStreams mode="switch">`: this list drawn in
    /// the player as a card over the running film (PlayerSourcesPanel), with the stream playing now
    /// first and marked "Now playing". nil is the picker. No home-server copies here (bp-streams
    /// `homeServerCopies = switching ? []`), no instant play, no source preference.
    var switching: PlayerSourcesPanel.Current? = nil
    /// The switcher's onClose (the player's closePanel); the picker dismisses its own cover instead.
    var onClose: (() -> Void)? = nil
    /// (S4) use-bp-stream-play openPlayerGated: this caller hands `Resolved.subtitlePreselect` to its
    /// PlayerScreen, so the subtitle step may stand between a pick and the player (Detail, Kids).
    var subtitleStep = false
    /// The search (StreamsModel) and the picker's state and logic (PlayPickerModel, App/Shared).
    @StateObject private var picker: PlayPickerModel
    /// The search engine model: the picker owns it and forwards its changes, so this view redraws on them.
    private var model: StreamsModel { picker.model }
    typealias AutoState = PlayPickerModel.AutoState
    typealias PickerDialog = PlayPickerModel.PickerDialog
    @Environment(\.dismiss) private var dismiss
    /// bp-streams autofocus on the first row (the first home-server copy, else the first
    /// stream), taken by the model's seed pass while the viewer has not moved: the model reaches
    /// both rings through `bindFocus`.
    @FocusState private var rowFocus: String?
    /// The quality chips ("q:<name>"); the cover's first ring lands on "q:All".
    @FocusState private var chipFocus: String?
    /// This picker's claim on the screensaver's suppression (use-bp-screensaver `!!picker`).
    @State private var saverKey = UUID().uuidString

    init(meta: Meta, episode: AnyJSON?, onPlay: @escaping (ScoredStream?, StreamsModel.Resolved) -> Void,
         autoPlay: Bool = false, applyPreference: Bool = false, switching: PlayerSourcesPanel.Current? = nil,
         onClose: (() -> Void)? = nil, subtitleStep: Bool = false) {
        self.meta = meta
        self.episode = episode
        self.onPlay = onPlay
        self.autoPlay = autoPlay
        self.applyPreference = applyPreference
        self.switching = switching
        self.onClose = onClose
        self.subtitleStep = subtitleStep
        _picker = StateObject(wrappedValue: PlayPickerModel(
            meta: meta, episode: episode, autoPlay: autoPlay, applyPreference: applyPreference,
            subtitleStep: subtitleStep, switching: switching, onPlay: onPlay, onClose: onClose))
    }

    var body: some View {
        // The model works from this pass's inputs: the closures and the switcher's playing stream can change.
        let _ = picker.update(switching: switching, onPlay: onPlay, onClose: onClose, dismiss: { dismiss() })
        ZStack {
            if switching != nil {
                switchCard
                // bp-streams: in the player the dialogs sit over the card inside the player, not
                // in a cover: a cover over the player takes it off screen (its onDisappear releases
                // the stream, Now Playing and the torrent while the film plays on).
                if let d = picker.dialog { dialogView(d).transition(.opacity) }
            } else {
                BPAmbientBackground()
                pickerSurface
            }
        }
        .ignoresSafeArea()
        .task { await picker.runSearch() }
        .task { await picker.runAutoLoop() }
        .task { await picker.consumeStubEvent() }
        .onAppear {
            let row = $rowFocus, chip = $chipFocus
            picker.bindFocus(row: (read: { row.wrappedValue }, write: { row.wrappedValue = $0 }),
                             chip: (read: { chip.wrappedValue }, write: { chip.wrappedValue = $0 }))
            picker.appeared()
        }
        .onChange(of: model.streams.count) { _, n in picker.streamCountChanged(n) }
        .onChange(of: model.setup) { _, setup in picker.setupChanged(setup) }
        .onChange(of: picker.firstRowKey) { _, _ in picker.seedRing() }
        .onChange(of: picker.showAutoStep) { _, busy in picker.autoStepChanged(busy: busy) }
        .onChange(of: picker.dialog == nil) { _, clear in if clear { picker.seedRing() } }
        .onChange(of: model.copiesLoaded) { _, loaded in if loaded { Task { await picker.applySourcePreference() } } }
        .onChange(of: model.phase) { _, phase in picker.phaseChanged(phase) }
        .onChange(of: picker.autoState) { _, state in picker.autoStateChanged(state) }
        .onDisappear { picker.disappeared() }
        // use-bp-screensaver: no saver over the picker or its dialogs (the in-player
        // switcher is under playback's suppression already).
        .onAppear { if switching == nil { ScreensaverModel.shared.picker(saverKey, up: true) } }
        .onDisappear { ScreensaverModel.shared.picker(saverKey, up: false) }
        .fullScreenCover(item: coverDialog) { d in
            dialogView(d)
                .onAppear { ScreensaverModel.shared.picker(saverKey + "-dialog", up: true) }
                .onDisappear { ScreensaverModel.shared.picker(saverKey + "-dialog", up: false) }
        }
    }

    /// The picker's dialogs come up in a cover; the in-player switcher's never do (drawn inline).
    private var coverDialog: Binding<PickerDialog?> {
        if switching != nil { return Binding<PickerDialog?>.constant(nil) }
        return $picker.dialog
    }

    /// The picker's own page: the subtitle step, the auto step, or the list beside the title's column.
    @ViewBuilder private var pickerSurface: some View {
        if picker.showAutoStep, picker.preselect == nil {
            // bp-streams.tsx: while auto is busy BpAutoStep stands in for the panel (a kid
            // profile's is auto-play-transition.tsx's kid branch).
            PickerAutoStep(meta: meta, episode: episode, attemptIdx: picker.autoTried, resolving: picker.autoFiring,
                           p2p: model.p2pStarting, kid: ProfilesStore.shared.active?.kid != nil,
                           stubNotice: picker.stubNotice, onCancel: { picker.cancelAuto() })
                .transition(.opacity)
        } else {
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Play").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                    Text(meta.name).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(3)
                    if let ep = picker.episodeLabel { Text(ep).font(BP.sans(16, .semibold)).foregroundStyle(BP.inkMuted) }
                    statusLine
                    if picker.stubNotice { stubBanner }
                    if let resolveError = picker.resolveError { BPNote(text: resolveError, tone: BP.danger) }
                    RemoteImage(url: meta.poster).frame(width: BP.px(177), height: BP.px(265)).clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)).padding(.top, BP.px(10))
                        .accessibilityHidden(true)
                }
                .frame(width: BP.px(300), alignment: .leading)
                list
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(50))
            // Kept under the subtitle step, hidden and out of the ring's reach, so Back
            // finds the picked row where it was: rebuilt, the lazy list started at the top and a
            // row further down was not there to take the ring.
            .opacity(picker.preselect == nil ? 1 : 0)
            .disabled(picker.preselect != nil)
        }
        if let pending = picker.preselect {
            // bp-streams.tsx: `if (play.preselect)` BpSubtitleStep stands in for the panel.
            SubtitleStepView(meta: meta, episode: episode, imdbId: model.imdb?.id, imdbVerified: model.imdb?.verified ?? false,
                             streamRef: pending.resolved.streamRef, filename: pending.resolved.data?.filename,
                             onStart: { choice in picker.startPreselect(choice) }, onCancel: { picker.cancelPreselect() })
                .transition(.opacity)
        }
    }

    // bp-stream-dialogs.tsx, one view per dialog. Back acts like the seeded button's escape
    // (useSeededFocus onBack): Cancel, Back, Back, Browse sources.
    @ViewBuilder private func dialogView(_ d: PickerDialog) -> some View {
        switch d {
        case .p2p(let s):
            StreamDialogShell(title: "Stream this via peer-to-peer?",
                              message: "This source isn't cached on your debrid, so Harbor would pull it directly from peers. It can take a moment to start and may buffer on low-seed torrents.") {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(s.parsedTitle ?? s.title ?? s.name ?? T("This source")).font(.system(size: BP.px(14), design: .monospaced)).foregroundStyle(BP.ink).lineLimit(2)
                    HStack(spacing: BP.px(12)) {
                        if let seeds = s.seeders { Label("\(Int(seeds)) seeders", systemImage: "person.2") }
                        if let sz = s.sizeText { Text(sz) }
                        let summary = badges(s).filter { $0 != "Cached" }
                        if !summary.isEmpty { Text(summary.joined(separator: " · ")) }
                    }
                    .font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle)
                    .accessibilityElement(children: .combine)
                }
                .padding(BP.px(14)).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
            } buttons: {
                Button("Cancel") { picker.dialog = nil }.buttonStyle(BPActionStyle())
                Button("Stream") { picker.streamViaP2p(s, always: false) }.buttonStyle(BPActionStyle(primary: true))
                Button("Always stream P2P") { picker.streamViaP2p(s, always: true) }.buttonStyle(BPActionStyle())
            }
            .onExitCommand { picker.dialog = nil }
        case .debridDown:
            StreamDialogShell(title: "Your debrid service can't process this right now.",
                              message: "Real-Debrid, TorBox, AllDebrid and Premiumize all have brief outages where they stop returning links. Wait a few minutes and try again, or check the service's status page.") {
                EmptyView()
            } buttons: {
                // use-pick-handler resetDebridDown: the streak clears and the list stays up.
                Button("Try again") { picker.resetDebridDown() }.buttonStyle(BPActionStyle(primary: true))
                Button("Back") { picker.closePicker() }.buttonStyle(BPActionStyle())
            }
            .onExitCommand { picker.closePicker() }
        case .noSources:
            // Upstream's second button ("Leave Big Picture and open settings") has no TV equivalent.
            StreamDialogShell(title: "No streaming sources yet",
                              message: T("Harbor needs at least one streaming source before it can play %@. Install a stream addon or add a debrid key in settings.", meta.name)) {
                EmptyView()
            } buttons: {
                Button("Back") { picker.closePicker() }.buttonStyle(BPActionStyle(primary: true))
            }
            .onExitCommand { picker.closePicker() }
        case .exhausted(let n):
            StreamDialogShell(title: "We could not find a working stream",
                              message: T("Harbor tried %lld sources for %@ and none of them played. Usually that means a debrid key has expired, no stream addon is installed yet, or nothing has this title cached.", n, picker.exhaustedLabel)) {
                EmptyView()
            } buttons: {
                Button("Browse sources") { picker.browseManually() }.buttonStyle(BPActionStyle(primary: true))
                Button("Back") { picker.closePicker() }.buttonStyle(BPActionStyle())
            }
            .onExitCommand { picker.browseManually() }
        }
    }

    @ViewBuilder private var autoBanner: some View {
        // While auto is busy PickerAutoStep covers the list; only its outcome shows here.
        switch picker.autoState {
        case .exhausted: BPNote(text: "Nothing started on its own. Pick a source.", tone: BP.inkMuted)
        default: EmptyView()
        }
    }

    /// play-picker.tsx stubBanner: the amber card over the list (border amber-300/30, fill
    /// amber-400/10, text amber-100).
    private var stubBanner: some View {
        Text("Last source wasn't actually cached on your debrid yet. Pick another from the list.")
            .font(BP.sans(13.5)).foregroundStyle(Color(red: 0.996, green: 0.953, blue: 0.78))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(12))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(Color(red: 0.984, green: 0.749, blue: 0.141).opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(Color(red: 0.988, green: 0.827, blue: 0.302).opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder private var statusLine: some View {
        autoBanner
        if model.p2pStarting {
            // A torrent is fetching its metadata in the TV's engine (bp-p2p-status "Looking for peers…").
            HStack(spacing: BP.px(8)) {
                ProgressView().tint(BP.accent).accessibilityHidden(true)
                Text("Looking for peers…").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
            }
        }
        switch model.phase {
        case .searching, .done:
            // bp-streams header: "Searching" or "{shown} of {total} sources", then "{n} addons loading".
            Text(verbatim: picker.sourcesLine).font(BP.sans(14, .medium)).foregroundStyle(BP.inkSubtle)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let why): BPNote(text: why, tone: BP.danger)
        case .idle: EmptyView()
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                ForEach(PlayPickerModel.qualities, id: \.0) { q in
                    let n = q.1.isEmpty ? picker.pool.count : picker.pool.filter { q.1.contains($0.resolution ?? "") }.count
                    if n > 0 || q.0 == "All" {
                        // A String, not a literal: "%@ %lld" is a catalog entry some languages re-order.
                        Button(T(q.0) + " \(n)") { picker.quality = q.0 }.buttonStyle(BPActionStyle(primary: picker.quality == q.0))
                            .bpSelected(picker.quality == q.0)
                            .focused($chipFocus, equals: "q:" + q.0)
                    }
                }
                // bp-stream-chips Cached chip with its count (cachedCount: every cached stream listed).
                if picker.cachedOnly || model.streams.contains(where: \.isCached) {
                    let cachedCount: Int = model.streams.filter(\.isCached).count
                    Button(T("Cached") + " \(cachedCount)") { picker.cachedOnly.toggle() }.buttonStyle(BPActionStyle(primary: picker.cachedOnly))
                        .bpSelected(picker.cachedOnly)
                }
                if picker.addons.count > 1 {
                    Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(24))
                    Button(picker.addonFilter ?? T("All addons")) { picker.stepAddonFilter() }.buttonStyle(BPActionStyle(primary: picker.addonFilter != nil))
                }
                // Facet chips cycle All → each value that exists (with counts), like bp-stream-menu.
                ForEach(PlayPickerModel.facets, id: \.key) { f in
                    let opts = picker.facetOptions(f)
                    if opts.count > 1 || picker.facet[f.key] != nil {
                        Button(picker.facet[f.key].map { v in "\(T(f.label)): \(v) \(opts.first { $0.0 == v }?.1 ?? 0)" } ?? T(f.label)) {
                            picker.stepFacet(f)
                        }.buttonStyle(BPActionStyle(primary: picker.facet[f.key] != nil))
                    }
                }
                // bp-stream-chips preferred-language chip: the languages' codes and how many streams
                // they hide, while any are hidden. It can leave with the ring on it, so it
                // stays drawn, dimmed and ignored, while it holds the ring (a vanished chip drops focus).
                let langCount: Int = picker.langHiddenCount
                if langCount > 0 || chipFocus == "lang" {
                    let label: String = model.setup?.langLabel ?? ""
                    Button(label + " \(langCount)") {
                        guard langCount > 0 else { return }
                        picker.langFilter.toggle()
                    }
                    .buttonStyle(BPActionStyle(primary: picker.langFilter, busy: langCount == 0))
                    .bpSelected(picker.langFilter)
                    .focused($chipFocus, equals: "lang")
                }
                // bp-stream-chips source chip: All sources, Media servers, Direct/debrid only, P2P only.
                Button(picker.sourceChipLabel) { picker.nextSource() }
                    .buttonStyle(BPActionStyle(primary: picker.sourceKind != "all" || model.streamMode != "both"))
                // bp-stream-chips filter chip: the saved stream filters (Settings → Stream filters on
                // the desktop), No filter first.
                if !model.savedFilters.isEmpty {
                    Button { picker.nextFilter() } label: { Label(picker.filterChipLabel, systemImage: "line.3.horizontal.decrease") }
                        .buttonStyle(BPActionStyle(primary: model.activeFilterId != nil))
                }
                Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(24))
                // Dimmed and ignored, not disabled, while an addon ranks its
                // own list: that flag can land with the ring on this chip, and a disabled button
                // drops focus on tvOS. Labels are bp-stream-chips' sort chip.
                Button {
                    picker.toggleSort()
                } label: {
                    Label(picker.sortChipLabel, systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(BPActionStyle(busy: model.addonRanked))
                if picker.filtered {
                    // The chip goes with the filters: the ring moves to "All"
                    // instead of falling off the row.
                    Button("Clear filters") { picker.clearFilters(); chipFocus = "q:All" }.buttonStyle(BPActionStyle())
                }
                // bp-stream-chips Refresh (use-pipeline-result refresh): the search runs again.
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(BPActionStyle())
            }
            .padding(.vertical, BP.px(6))
            // The fade lives in the gap left of the column: the chips start where the rows do.
            .padding(.leading, BP.px(28))
        }
        .scrollClipDisabled()
        // Scrolled along to Refresh, the chips ran out of their column over the
        // title on the left ("PLAY / Digger" under "All 6"). They fade out at the column's own
        // leading edge; the mask is taller than the strip so a focused chip's lift still draws.
        .mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: BP.px(28))
                Color.black
            }
            .padding(.vertical, -BP.px(24))
            .padding(.trailing, -BP.gutter)
        )
        .padding(.leading, -BP.px(28))
        .focusSection()
    }

    /// bp-streams.tsx switch mode (SWITCH_SURFACE over a 50% void scrim): a card the size of the
    /// player's other panels (the Audio dialog's frame), "Switch source", the title line with the
    /// source counts, the chips and rows, and the footer note.
    private var switchCard: some View {
        ZStack {
            BP.void_.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: BP.px(5)) {
                    Text("Switch source").font(BP.display(26)).foregroundStyle(BP.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: picker.switchHeading + " · " + picker.sourcesLine)
                        .font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    if model.p2pStarting {
                        HStack(spacing: BP.px(8)) {
                            ProgressView().tint(BP.accent).accessibilityHidden(true)
                            Text("Looking for peers…").font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                        }
                    }
                    if case .failed(let why) = model.phase { BPNote(text: why, tone: BP.danger) }
                    if let resolveError = picker.resolveError { BPNote(text: resolveError, tone: BP.danger) }
                }
                .padding(.horizontal, BP.px(30)).padding(.top, BP.px(30)).padding(.bottom, BP.px(6))

                list
                    .padding(.horizontal, BP.px(30))
                    .frame(maxHeight: .infinity, alignment: .top)

                Text("Pick a source to swap in place. Playback keeps running.")
                    .font(BP.sans(12.5, .semibold)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BP.px(30)).padding(.vertical, BP.px(12))
                    .overlay(alignment: .top) { Rectangle().fill(BP.edge).frame(height: 1) }
            }
            .frame(width: BP.px(1049), height: BP.px(551), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_))
            .clipShape(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .focusSection()
            // The dialog over the card owns the remote while it is up.
            .disabled(picker.dialog != nil)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            chips
            // bp-streams: the saved filter matched nothing, so the whole list is back.
            if picker.filterPool.fellBack, model.activeFilterId != nil {
                BPNote(text: "No sources match your filter. Showing all sources.")
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(10)) {
                    let rows: [ScoredStream] = picker.showOnline ? picker.visible : []
                    if picker.showHomeServers, !model.copies.isEmpty {
                        Text("On your home servers").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted)
                        ForEach(model.copies) { c in copyRow(c) }
                        if !rows.isEmpty { Text("Addons").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted).padding(.top, BP.px(6)) }
                    }
                    ForEach(rows) { s in row(s, highlight: picker.isHighlighted(s)) }
                    if rows.isEmpty, !picker.showHomeServers || model.copies.isEmpty { emptyList }
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.vertical, BP.px(6))
                // Room for the focused row's lift and edge: the scroll view
                // clipped them at its sides, leaving two stray white lines above and below the row.
                .padding(.horizontal, BP.px(8))
            }
            .focusSection()
        }
    }

    /// bp-streams empty state: a spinner while the search runs, else "No sources found" (nothing
    /// listed at all) with the loosen ladder, or "No sources match these filters".
    private var emptyList: some View {
        VStack(spacing: BP.px(12)) {
            if picker.listLoading {
                ProgressView().tint(BP.inkSubtle).accessibilityHidden(true)
            } else {
                Image(systemName: "shippingbox").font(.system(size: BP.px(30), weight: .regular)).foregroundStyle(BP.inkSubtle)
                    .accessibilityHidden(true)
            }
            let note: String = picker.listLoading ? "Looking for sources" : (picker.pool.isEmpty ? "No sources found" : "No sources match these filters")
            Text(verbatim: T(note))
                .font(BP.sans(16, .semibold)).foregroundStyle(BP.inkSubtle)
            // bp-streams ladder: nothing listed at all, so widen the search, then show everything. The
            // pressed button goes with the list, so the ring waits on the "All" chip.
            if !picker.listLoading, picker.pool.isEmpty, model.canLoosen {
                HStack(spacing: BP.px(10)) {
                    if model.strict {
                        Button("Search wider") { chipFocus = "q:All"; Task { await model.searchWider() } }
                            .buttonStyle(BPActionStyle(primary: true))
                    }
                    if !model.showAll {
                        Button("Show everything") { chipFocus = "q:All"; Task { await model.showEverything() } }
                            .buttonStyle(BPActionStyle())
                    }
                }
                .focusSection()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BP.px(40))
    }

    private func row(_ s: ScoredStream, highlight: Bool) -> some View {
        Button {
            // The stream playing now is picked like any other row: use-stream-switcher
            // onSwitchStream resolves it again (a fresh debrid link, the same torrent) and reloads it
            // in place at the resume spot, which is how a stalled or dead copy is brought back.
            // One pick at a time, guarded here rather than by disabling every row.
            // Held from the press (rowPressed): a double press resolved the row twice.
            picker.rowPressed(s)
        } label: {
            VStack(alignment: .leading, spacing: BP.px(5)) {
                HStack(alignment: .center, spacing: BP.px(10)) {
                    // The pills take what the marks on the right leave (a Spacer beside a wrapping
                    // row would be offered half and wrap early).
                    Group {
                        if let labels = s.tvLabels {
                            rowMeta(s, labels)
                        } else {
                            HStack(spacing: BP.px(8)) {
                                ForEach(badges(s), id: \.self) { b in
                                    Text(b == "Cached" ? T("Cached") : b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4)
                                        .foregroundStyle(b == "Cached" ? BP.canvas : BP.ink)
                                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                                        .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(b == "Cached" ? BP.live : BP.on))
                                }
                                Text(s.addonName).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // bp-stream-row: the stream playing now wears "Now playing" (the switcher), else
                    // the remembered pick "Played last".
                    if let current = switching, current.matches(s) {
                        // bp-stream-row PILL_STATE: an outlined capsule (edge-2), uppercase, ink.
                        Text("Now playing")
                            .font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(9)).padding(.vertical, BP.px(4))
                            .overlay(Capsule().stroke(BP.edge2, lineWidth: 1))
                            .fixedSize()
                    } else if model.rememberedIndex == s.index {
                        Label("Played last", systemImage: "clock.arrow.circlepath")
                            .font(BP.sans(10.5, .bold)).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(2))
                            .background(Capsule().fill(BP.glass))
                            .fixedSize()
                    }
                    if let labels = s.tvLabels { availabilityMark(labels) }
                    if picker.resolving == s.id { ProgressView().tint(BP.inkMuted).scaleEffect(0.7).accessibilityHidden(true) }
                }
                let headline = s.tvRow?.headline ?? s.parsedTitle ?? s.title ?? s.name ?? "Stream"
                // A multi-line addon name ("[RD+] Torrentio\n4k") drew as
                // "[RD+] Torrentio…": the first line alone, whole.
                Text(Self.firstLine(headline)).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                // bp-stream-row.tsx: the addon's whole description (fullStreamDescription), else the
                // one-line summary; both with the pictographs dropped (engine stampPickerRows).
                if let text = s.tvRow, SettingsBridge.shared.slice.fullStreamDescription ?? true, !text.description.isEmpty {
                    Text(verbatim: Self.tidy(text.description)).font(BP.sans(12, .medium)).foregroundStyle(BP.inkMuted).lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let text = s.tvRow, !text.detail.isEmpty {
                    Text(verbatim: text.detail).font(BP.sans(12, .medium)).foregroundStyle(BP.inkMuted).lineLimit(1)
                } else {
                    HStack(spacing: BP.px(10)) {
                        if let g = s.releaseGroup { Text(g) }
                        if let sz = s.sizeText { Text(sz) }
                        if let seeds = s.seeders, seeds > 0 { Text("\(Int(seeds)) seeders") }
                        if let langs = s.audioLanguages, !langs.isEmpty { Text(langs.prefix(3).joined(separator: ", ")) }
                    }
                    .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                }
                // settings.pickerShowFilename: the torrent's filename in mono, unless it is the headline.
                if SettingsBridge.shared.slice.pickerShowFilename ?? false, let name = s.tvRow?.filename, !name.isEmpty, name != headline, name != s.tvRow?.headline {
                    Text(verbatim: name).font(.system(size: BP.px(11), design: .monospaced)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
                if picker.failedIds.contains(s.id) {
                    Text("Unavailable, try another.").font(BP.sans(12, .bold)).foregroundStyle(BP.ink)
                }
            }
            .padding(BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(highlight ? BP.panel2 : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(highlight ? BP.accent.opacity(0.6) : BP.edge, lineWidth: 1))
            .opacity(picker.failedIds.contains(s.id) ? 0.7 : 1)
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM, lift: 1.012))
        // Was .disabled(resolving != nil): the pressed row turned unfocusable the moment
        // its resolve began, so the ring was thrown onto the filter chips and stayed there when the
        // link failed ("Unavailable, try another."), a whole list away from the next row to try.
        .focused($rowFocus, equals: "stream:" + s.id)
        .bpSelected(highlight)
        .accessibilityIdentifier("stream-\(s.index)")
    }

    static func firstLine(_ text: String) -> String {
        let line: Substring = text.split(whereSeparator: { $0.isNewline }).first ?? Substring(text)
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// With the pictographs dropped (engine stampPickerRows) an addon description
    /// kept their separators: a line of "////" and trailing " /". Lines of punctuation alone go, and
    /// a trailing separator is trimmed.
    static func tidy(_ text: String) -> String {
        let junk = CharacterSet(charactersIn: "/|·•-–—_ ").union(.whitespaces)
        let lines: [String] = text.split(whereSeparator: { $0.isNewline }).compactMap { raw in
            var line: String = String(raw).trimmingCharacters(in: .whitespaces)
            while let last = line.unicodeScalars.last, junk.contains(last) { line.removeLast() }
            let hasContent: Bool = line.unicodeScalars.contains { !junk.contains($0) }
            return hasContent ? line : nil
        }
        return lines.joined(separator: "\n")
    }

    /// bp-stream-row.tsx META: the quality pill (showQualityBadge), the addon's name, the DUB/SUB
    /// pill (showDubBadge, anime only), the format badges (showQualityBadge) and the edition. It
    /// wraps like upstream's flex-wrap rather than squeezing the pills.
    private func rowMeta(_ s: ScoredStream, _ labels: ScoredStream.Labels) -> some View {
        let slice = SettingsBridge.shared.slice
        let showQuality: Bool = slice.showQualityBadge ?? true
        let showDub: Bool = slice.showDubBadge ?? true
        return PickerFlowRow(spacing: BP.px(8), lineSpacing: BP.px(6)) {
            if showQuality {
                // "No Label" and "Unverified" are catalog keys; QUALITY_LABEL values are not translated upstream.
                let quality: String = labels.confidence == "labeled" ? labels.quality : T(labels.quality)
                Text(verbatim: quality).font(BP.sans(12.5, .heavy)).foregroundStyle(BP.ink).lineLimit(1)
                    .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(2))
                    .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.glass))
            }
            Text(verbatim: s.addonName).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.inkMuted)
                .lineLimit(1).frame(maxWidth: BP.px(240), alignment: .leading)
            if showDub, let kind = labels.dubSub { dubSubPill(kind) }
            if showQuality, let formats = labels.formats {
                // bp-stream-row `badges.map(FormatBadge)`: the badge images.
                ForEach(formats, id: \.kind) { b in formatBadge(b) }
            } else if showQuality {
                ForEach(labels.badges, id: \.self) { b in
                    Text(verbatim: b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4).foregroundStyle(BP.ink).lineLimit(1)
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                        .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.on))
                }
            }
            if let edition = labels.edition {
                Text(verbatim: edition).font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.inkMuted).lineLimit(1)
                    .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(3))
                    .background(Capsule().fill(BP.glass))
            }
            // bp-stream-row.tsx: the audio languages' flags, last in META (FlagStack max 4, md).
            let flagLangs: [String] = FlagStack.streamLanguages(s.audioLanguages)
            if !flagLangs.isEmpty { FlagStack(languages: flagLangs, maxCount: 4, size: .md) }
        }
    }

    /// format-badge.tsx FormatBadge size "md": the image at 80% of MAX_HEIGHT
    /// (40), no wider than 1.8 x WIDTH (42), with its two drop shadows; the badge's name when the
    /// image is missing from the bundle.
    @ViewBuilder private func formatBadge(_ b: ScoredStream.Labels.Format) -> some View {
        if let art = StreamBadgeArt.image(b.file) {
            // 32 px canvas (54 pt) badges pushed half the row onto a second line.
            let height: CGFloat = BP.px(22)
            let aspect: CGFloat = art.size.height > 0 ? art.size.width / art.size.height : 1
            let width: CGFloat = min(BP.px(75.6), height * aspect)
            Image(uiImage: art).resizable().scaledToFit()
                .frame(width: width, height: height)
                .shadow(color: Color.black.opacity(0.55), radius: 1)
                .shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
                .accessibilityLabel(Text(verbatim: b.text))
        } else {
            Text(verbatim: b.text).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4).foregroundStyle(BP.ink).lineLimit(1)
                .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.on))
        }
    }

    /// components/dub-sub-pill.tsx: SUB quiet, DUB in the accent, DUAL in emerald.
    private func dubSubPill(_ kind: String) -> some View {
        let text: String = kind == "dual" ? "DUAL" : (kind == "dub" ? "DUB" : "SUB")
        let emerald300 = Color(red: 0.431, green: 0.906, blue: 0.718)
        let emerald400 = Color(red: 0.204, green: 0.827, blue: 0.600)
        let emerald500 = Color(red: 0.063, green: 0.725, blue: 0.506)
        let fg: Color = kind == "dual" ? emerald300 : (kind == "dub" ? BP.accent : BP.inkSubtle)
        let bg: Color = kind == "dual" ? emerald500.opacity(0.15) : (kind == "dub" ? BP.accent.opacity(0.15) : BP.canvas.opacity(0.7))
        let ring: Color = kind == "dual" ? emerald400.opacity(0.3) : (kind == "dub" ? BP.accent.opacity(0.35) : BP.edge)
        return Text(verbatim: text).font(BP.sans(10, .bold)).tracking(0.8).foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
            .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: BP.px(4)).stroke(ring, lineWidth: 1))
    }

    /// bp-stream-row.tsx right-hand mark: "In {name}" (your own cloud), "Cached on {name}", "Cached";
    /// else External, P2P, or Cache (a source the debrid would have to fetch first).
    @ViewBuilder private func availabilityMark(_ labels: ScoredStream.Labels) -> some View {
        let kind: String = labels.availability ?? ""
        if kind == "cached" {
            HStack(spacing: BP.px(6)) {
                Image(systemName: "checkmark").font(.system(size: BP.px(13), weight: .heavy)).foregroundStyle(BP.live)
                    .accessibilityHidden(true)
                Text(verbatim: cachedText(labels)).font(BP.sans(11.5, .bold)).foregroundStyle(BP.ink).lineLimit(1)
            }
            .fixedSize()
        } else if kind == "external" {
            markPill(T("External"), icon: "arrow.up.right.square")
        } else if kind == "p2p" {
            markPill(T("P2P"), icon: "point.3.connected.trianglepath.dotted")
        } else if kind == "cache" {
            markPill(T("Cache"), icon: "arrow.down.to.line")
        }
    }

    private func cachedText(_ labels: ScoredStream.Labels) -> String {
        guard let on = labels.cachedOn else { return T("Cached") }
        return on.owned ? T("In %@", on.name) : T("Cached on %@", on.name)
    }

    /// bp-stream-row PILL: an outlined capsule, muted.
    private func markPill(_ text: String, icon: String) -> some View {
        HStack(spacing: BP.px(5)) {
            Image(systemName: icon).font(.system(size: BP.px(11), weight: .bold))
                .accessibilityHidden(true)
            Text(verbatim: text).lineLimit(1)
        }
        .font(BP.sans(11, .bold)).foregroundStyle(BP.inkMuted)
        .padding(.horizontal, BP.px(9)).padding(.vertical, BP.px(4))
        .overlay(Capsule().stroke(BP.edge, lineWidth: 1))
        .fixedSize()
    }

    /// A copy on a Plex/Jellyfin/Emby server (bp-streams home-server rows): direct play or transcode through the server.
    private func copyRow(_ c: StreamsModel.HomeCopy) -> some View {
        Button {
            picker.copyPressed(c)
        } label: {
            VStack(alignment: .leading, spacing: BP.px(5)) {
                HStack(spacing: BP.px(8)) {
                    ForEach([c.resolution, c.quality].compactMap { $0 }.filter { !$0.isEmpty && $0 != "unknown" }, id: \.self) { b in
                        Text(b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                            .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.on))
                    }
                    if c.progressMs > 0 { Text("Resume").font(BP.sans(10, .bold)).textCase(.uppercase).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.live)) }
                    Spacer()
                    Text(c.sourceLabel).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                    if picker.resolving == c.key { ProgressView().tint(BP.inkMuted).scaleEffect(0.7).accessibilityHidden(true) }
                }
                Text(c.label).font(BP.sans(14)).foregroundStyle(BP.ink).lineLimit(2)
                if let b = c.sizeBytes, b > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
            }
            .padding(BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM, lift: 1.012))
        .focused($rowFocus, equals: "copy:" + c.key)
    }

    private func badges(_ s: ScoredStream) -> [String] {
        var out: [String] = []
        if s.isCached { out.append("Cached") }
        if let r = s.resolution, r != "unknown" { out.append(r) }
        if let h = s.hdrFormat { out.append(h) }
        if let c = s.codec, c != "unknown", c != "Other" { out.append(c) }
        if let a = s.audio?.codec, a != "Other" { out.append(a + ((s.audio?.channels ?? 0) >= 6 ? " 5.1" : "")) }
        if s.remux == true { out.append("Remux") }
        if let src = s.source, !["unknown", "other"].contains(src.lowercased()) { out.append(src) }
        return out
    }

    /// The message for a link no URL can be made of; PlayerKids reads it from here.
    static var badLinkMessage: String { PlayPickerModel.badLinkMessage }
}

/// bp-stream-dialogs BpDialogShell: title, body, an optional detail card, then a row of buttons.
struct StreamDialogShell<Extra: View, Buttons: View>: View {
    let title: String
    let message: String
    let extra: Extra
    let buttons: Buttons

    init(title: String, message: String, @ViewBuilder extra: () -> Extra, @ViewBuilder buttons: () -> Buttons) {
        self.title = title
        self.message = message
        self.extra = extra()
        self.buttons = buttons()
    }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.8).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(22)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text(T(title)).font(BP.display(26)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
                    Text(T(message)).font(BP.sans(15)).foregroundStyle(BP.inkSubtle).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                extra
                HStack(spacing: BP.px(12)) { buttons }
                    .focusSection()
            }
            .padding(BP.px(40))
            .frame(width: BP.px(720), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
        }
    }
}

/// bp-stream-row.tsx META (`flex flex-wrap`): the row's pills left to right, wrapping onto another
/// line when they run out of room instead of squeezing.
struct PickerFlowRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth: CGFloat = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size: CGSize = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size: CGSize = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
