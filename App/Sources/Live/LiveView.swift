import SwiftUI


struct LiveView: View {
    @StateObject private var model: LiveModel
    /// (open-items sweep 2) The shell's store: bp-view-state's liveCategory (bp-live.tsx
    /// useBpPersistedState("liveCategory")). The room is built afresh on every tab switch, so the
    /// chip came back on All after every visit to another tab.
    private let views: ShellViewState

    init(views: ShellViewState) {
        self.views = views
        _model = StateObject(wrappedValue: LiveModel(category: views.liveCategory))
    }
    @State private var playing: LiveModel.Channel?
    @State private var replaying: Replay?
    struct Replay: Identifiable { var id: String { url }; var channel: LiveModel.Channel; var program: LiveModel.Program; var url: String; var headers: [String: String] }
    @State private var showSources = false
    /// bp-live shows the guide grid; the list is the fallback when a source has no guide.
    @State private var grid = true
    @State private var showHidden = false
    /// epg-match-modal: the channel whose guide match is being picked.
    @State private var matching: LiveModel.Channel?
    /// view-mode-toggle.tsx "Multiview"; `multiviewSeed` is the channel "Add to Multiview" brought.
    @State private var showMultiview = false
    @State private var multiviewSeed: LiveModel.Channel?
    /// Set by the player's "Add to Multiview"; Multiview opens once the player's cover is gone
    /// (a present-while-dismissing is dropped on tvOS).
    @State private var pendingMultiview: LiveModel.Channel?
    /// nav "Playlists" (views/playlist-vod.tsx): the source's movies and shows.
    @State private var showVod = false

    /// The channel the viewer opened the player on (the player's TV Guide may tune others).
    @State private var openedChannel: String?
    @FocusState private var listFocus: String?
    @FocusState private var bandFocus: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !model.sourcesRead {
                // Nothing until the sources are known (see sourcesRead).
                Color.clear
            } else if model.playlists.isEmpty && !model.loading {
                LiveSourcesSheet(model: model, firstRun: true, dismiss: {})
            } else {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    band
                    if model.loading && model.channels.isEmpty {
                        ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, alignment: .center).padding(.top, BP.px(60))
                    } else if model.visible.isEmpty {
                        emptyState
                    } else if grid && model.guideNote == nil {
                        LiveGuideView(live: model, play: { ch in open(ch) }, star: { ch in star(ch) },
                                      replay: { ch, prog in Task { await startReplay(ch, prog) } },
                                      previewSuspended: playing != nil || replaying != nil || showSources || matching != nil || showMultiview || showVod,
                                      match: { ch in matching = ch })
                    } else {
                        guideList
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(16))
            }
        }
        .task { await model.appear() }
        .onChange(of: model.guideNote) { old, new in
            // (open-items sweep) The grid and the list swap when the guide note comes or goes (a guide
            // that fails late, an Xtream short EPG that lands). The view under the ring went away and
            // the ring fell back to the band; it now lands on the same channel in the other view.
            guard grid else { return }
            let from: String? = old == nil ? model.guideFocusChannel : listFocus
            guard (old == nil) != (new == nil), let id = from else { return }
            model.guideFocusChannel = nil
            DispatchQueue.main.async { model.focusRequest = LiveModel.FocusRequest(channelId: id) }
        }
        .fullScreenCover(item: $playing, onDismiss: {
            // Back from the player puts the ring on the channel that was
            // playing: after zapping in the player's TV Guide it stayed on the first channel's row.
            if let last = model.lastPlayedId, last != openedChannel, pendingMultiview == nil { model.focusRequest = LiveModel.FocusRequest(channelId: last) }
            openedChannel = nil
            guard let ch = pendingMultiview else { return }
            pendingMultiview = nil
            multiviewSeed = ch
            showMultiview = true
        }) { ch in
            PlayerScreen(title: ch.name, subtitle: model.guide[ch.id]?.now?.title ?? ch.group, url: URL(string: ch.url) ?? URL(string: "about:blank")!, headers: ch.headers ?? [:], isLive: true,
                         liveGuide: model, liveChannel: ch, onAddToMultiview: { pendingMultiview = $0 }) { _ in playing = nil }
        }
        .fullScreenCover(isPresented: $showMultiview, onDismiss: { multiviewSeed = nil }) {
            MultiviewView(live: model, seed: multiviewSeed, dismiss: { showMultiview = false })
        }
        .fullScreenCover(isPresented: $showVod) {
            PlaylistVodView(dismiss: { showVod = false })
        }
        .fullScreenCover(item: $replaying) { r in
            // A bounded replay: VOD cache profile, seekable, subtitle says so (use-live-actions.ts).
            PlayerScreen(title: r.program.title, subtitle: T("%@ · catch up", r.channel.shownName), url: URL(string: r.url) ?? URL(string: "about:blank")!, headers: r.headers, isLive: false) { _ in replaying = nil }
        }
        .fullScreenCover(isPresented: $showSources) {
            LiveSourcesSheet(model: model, firstRun: false, dismiss: { showSources = false })
        }
        .fullScreenCover(item: $matching) { ch in
            EpgMatchView(model: model, channel: ch, dismiss: { matching = nil })
        }
    }

    /// bp-live setKey (useBpPersistedState): a chip the viewer picks is kept for the next visit.
    private func pick(_ key: String) {
        model.category = key
        model.keptCategory = key
        views.liveCategory = key
    }

    private func open(_ ch: LiveModel.Channel) {
        // A second Select while the cover is still coming up is ignored.
        guard playing == nil, replaying == nil else { return }
        model.played(ch)
        openedChannel = ch.id
        playing = ch
    }

    /// Unstarring a channel on the Favorites chip takes its row out from under
    /// the ring: the ring goes to the row now in its place (the next, else the one before), or to
    /// the Favorites chip when that was the last one, instead of falling to the top bar. The grid
    /// moves its own ring (LiveGuideView.starPressed); the list's is moved here.
    private func star(_ ch: LiveModel.Channel) {
        if model.category == LiveModel.favKey, ch.favorite, !grid || model.guideNote != nil {
            let ids: [String] = model.visibleIds
            if let i = ids.firstIndex(of: ch.id) {
                if i + 1 < ids.count { listFocus = ids[i + 1] }
                else if i > 0 { listFocus = ids[i - 1] }
                else { bandFocus = "chip:" + LiveModel.favKey }
            }
        } else if model.category == LiveModel.favKey, ch.favorite, model.visibleIds == [ch.id] {
            bandFocus = "chip:" + LiveModel.favKey
        }
        Task { await model.toggleFavorite(ch) }
    }

    private func startReplay(_ ch: LiveModel.Channel, _ prog: LiveModel.Program) async {
        struct Out: Decodable { var url: String; var headers: [String: String]? }
        guard let id = model.selectedPlaylist,
              let out: Out? = try? await HarborEngine.shared.call("live.catchupUrl", [id, ch.id, prog.startMs, prog.endMs]), let out else {
            open(ch); return
        }
        guard playing == nil, replaying == nil else { return }
        model.played(ch)
        replaying = Replay(channel: ch, program: prog, url: out.url, headers: out.headers ?? [:])
    }

    // bp-live.tsx: source button, then Favorites / All / groups chips (max 30).
    private var band: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                Button {
                    showSources = true
                } label: {
                    HStack(spacing: BP.px(6)) {
                        Image(systemName: "antenna.radiowaves.left.and.right").accessibilityHidden(true)
                        Text(model.playlists.first { $0.id == model.selectedPlaylist }?.name ?? T("Sources"))
                        if model.loading && !model.channels.isEmpty {
                            // Refresh now closes Sources at once: the
                            // reload shows here while the current channels stay up.
                            ProgressView().scaleEffect(0.5).frame(width: BP.px(16), height: BP.px(16))
                        }
                    }
                }
                .buttonStyle(BPActionStyle(primary: true))
                // view-mode-toggle.tsx "Multiview": up to four channels at once.
                Button { multiviewSeed = nil; showMultiview = true } label: {
                    Label("Multiview", systemImage: "rectangle.split.2x2")
                }
                .buttonStyle(BPActionStyle())
                // nav "Playlists": the movies and shows the sources carry (views/playlist-vod.tsx).
                Button { showVod = true } label: {
                    Label("Playlists", systemImage: "film.stack")
                }
                .buttonStyle(BPActionStyle())
                // bp-live-filters: star on Favorites, a flag on country groups, no count at zero.
                ForEach(model.categories, id: \.key) { c in
                    Button {
                        pick(c.key)
                        Task { await model.refreshNowNext() }
                    } label: {
                        HStack(spacing: BP.px(6)) {
                            if c.key == LiveModel.favKey {
                                Image(systemName: c.count > 0 ? "star.fill" : "star").accessibilityHidden(true)
                            }
                            if let flag = c.flag {
                                RemoteImage(url: flag, contentMode: .fill)
                                    .frame(width: BP.px(18), height: BP.px(12))
                                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                                    .accessibilityHidden(true)
                            }
                            Text(c.label).lineLimit(1)
                            if c.count > 0 {
                                Text("\(c.count)").opacity(0.55)
                            }
                        }
                    }
                    .buttonStyle(BPActionStyle(primary: model.category == c.key)).bpSelected(model.category == c.key)
                    .focused($bandFocus, equals: "chip:" + c.key)
                }
                // Hide group and Show … leave the band under the ring; the
                // ring is moved first (to All, or to the hidden-groups toggle while some remain)
                // instead of falling out of the band to the top bar.
                if let group = model.currentGroup {
                    Button("Hide group") {
                        bandFocus = "chip:" + LiveModel.allKey
                        pick(LiveModel.allKey)
                        Task { await model.toggleGroupHidden(group) }
                    }
                    .buttonStyle(BPActionStyle())
                }
                if showHidden {
                    ForEach(model.groups.filter { $0.hidden == true }) { g in
                        Button("Show \(g.name)") {
                            bandFocus = model.hiddenGroupCount > 1 ? "hidden" : "chip:" + LiveModel.allKey
                            Task { await model.toggleGroupHidden(g.name) }
                        }
                        .buttonStyle(BPActionStyle())
                    }
                }
                if model.hiddenGroupCount > 0 {
                    Button("\(model.hiddenGroupCount) hidden") { showHidden.toggle() }.buttonStyle(BPActionStyle(primary: showHidden))
                        .focused($bandFocus, equals: "hidden")
                }
                if model.guideNote == nil {
                    Button(grid ? "List" : "Guide") { grid.toggle() }.buttonStyle(BPActionStyle())
                }
                if let note = model.guideNote { BPNote(text: note).padding(.leading, BP.px(8)) }
            }
            .padding(.vertical, BP.px(4))
        }
        // 7 pt of track padding against a ring 9.5 pt out: the clip shaved the top and
        // bottom of the focused chip's ring and the whole left side of the first chip's.
        .scrollClipDisabled()
        .focusSection()
    }

    private var guideList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                    ForEach(model.visible) { ch in
                        LiveChannelRow(channel: ch, nowNext: model.guide[ch.id], focus: $listFocus,
                                       play: { open(ch) },
                                       star: { star(ch) },
                                       pin: { Task { await model.togglePin(ch) } },
                                       match: model.canMatchEpg(ch) ? { matching = ch } : nil)
                            .id(ch.id)
                            .onAppear { model.askNowNext(ch.id) }
                    }
                }
                .padding(.vertical, BP.px(8)).padding(.bottom, BP.hintHeight + BP.px(40))
                .padding(.horizontal, Self.listHeadroom)
            }
            // The rows fill the scroller edge to edge: a focused row (~1 310 pt wide, 1.03
            // lift) reaches ~29 pt past its sides with the ring, and the clip cut the ring's left side
            // (and the right side of the last cell). bp-grid's HEADROOM: pad inside, pull out as much.
            .padding(.horizontal, -Self.listHeadroom)
            .focusSection()
            .onChange(of: model.focusRequest) { _, request in
                guard let id = request?.channelId else { return }
                model.focusRequest = nil
                guard model.visibleIds.contains(id) else { return }
                proxy.scrollTo(id, anchor: .center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { listFocus = id }
            }
        }
    }

    /// bp-live.tsx BpLiveEmpty: a title, a line and one action, so the ring has somewhere to go
    /// below the band. It was a bare note: a playlist that failed to
    /// load could only be retried from Sources, and an empty Favorites had no way back to All.
    private var emptyState: some View {
        let failed = model.error != nil
        let favorites = model.category == LiveModel.favKey
        let title: String = failed ? T("Couldn't load this playlist") : (favorites ? T("No favorites yet") : T("No channels here"))
        let line: String = failed
            ? (model.error ?? "")
            : (favorites ? T("Press the star on any channel to keep it at the top of the guide.") : T("This playlist came back without any live channels."))
        let action: String = failed ? T("Try again") : (favorites ? T("Show all channels") : T("Add a playlist"))
        return VStack(spacing: BP.px(10)) {
            Text(title).font(BP.display(30)).foregroundStyle(BP.ink).multilineTextAlignment(.center)
            Text(line).font(BP.sans(16, .medium)).foregroundStyle(BP.inkSubtle).multilineTextAlignment(.center).lineLimit(4)
                .frame(maxWidth: BP.px(620))
            Button(action) {
                if failed { Task { await model.loadChannels(force: true) } }
                else if favorites { pick(LiveModel.allKey) }
                else { showSources = true }
            }
            .buttonStyle(BPActionStyle(primary: true, busy: failed && model.loading))
            .padding(.top, BP.px(8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BP.px(60))
        .focusSection()
    }

    private static let listHeadroom = BP.px(18)
}

/// One guide row: logo, name, what's on now (with a live progress bar), what's next, a star.
struct LiveChannelRow: View {
    let channel: LiveModel.Channel
    let nowNext: LiveModel.NowNext?
    /// The list's ring, keyed by channel id on the row's main button (restored after the player).
    let focus: FocusState<String?>.Binding
    let play: () -> Void
    let star: () -> Void
    var pin: (() -> Void)? = nil
    /// Opens the EPG match picker (only offered when there is something to match or clear).
    var match: (() -> Void)? = nil

    private var progress: Double? {
        guard let p = nowNext?.now else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        guard p.endMs > p.startMs else { return nil }
        return min(1, max(0, (now - p.startMs) / (p.endMs - p.startMs)))
    }

    var body: some View {
        HStack(spacing: BP.px(8)) {
            Button(action: play) {
                HStack(spacing: BP.px(14)) {
                    RemoteImage(url: channel.logo, contentMode: .fit)
                        .frame(width: BP.px(84), height: BP.px(46))
                        .background(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous).fill(BP.void_.opacity(0.6)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        HStack(spacing: BP.px(6)) {
                            Text(channel.shownName).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            if let b = channel.badge { Text(b).font(BP.sans(9, .bold)).foregroundStyle(BP.inkMuted).padding(.horizontal, 4).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).stroke(BP.edge2, lineWidth: 1)) }
                        }
                        if let g = channel.groupLabel ?? channel.group { Text(g).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                    }
                    .frame(width: BP.px(220), alignment: .leading)
                    VStack(alignment: .leading, spacing: BP.px(4)) {
                        HStack(spacing: BP.px(8)) {
                            Circle().fill(BP.live).frame(width: BP.px(6), height: BP.px(6))
                                .accessibilityHidden(true)
                            Text(nowNext?.now?.title ?? T(nowNext?.known == true ? "No program info" : "Live"))
                                .font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            if let p = nowNext?.now { Text(Self.range(p)).font(BP.sans(11)).foregroundStyle(BP.inkMuted) }
                        }
                        if let progress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(BP.edge2)
                                    Capsule().fill(BP.live).frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: BP.px(3))
                            .bpProgressValue(progress)
                        }
                        if let n = nowNext?.next {
                            Text(T("Next %@", Self.time(n.startMs)) + " · " + n.title).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .focused(focus, equals: channel.id)
            Button(action: star) {
                Image(systemName: channel.favorite ? "star.fill" : "star")
                    .font(.system(size: BP.px(16), weight: .bold))
                    .foregroundStyle(channel.favorite ? BP.ink : BP.inkMuted)
                    .frame(width: BP.px(56), height: BP.px(56))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .accessibilityLabel(channel.favorite ? T("Remove from favorites") : T("Add to favorites"))
            if let pin {
                // usePinnedOrder: a pinned channel sits just under the favourites in guide order.
                Button(action: pin) {
                    Image(systemName: channel.pinned == true ? "pin.fill" : "pin")
                        .font(.system(size: BP.px(16), weight: .bold))
                        .foregroundStyle(channel.pinned == true ? BP.ink : BP.inkMuted)
                        .frame(width: BP.px(56), height: BP.px(56))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
                .accessibilityLabel(channel.pinned == true ? T("Unpin channel") : T("Pin channel"))
            }
            if let match {
                // guide-view.tsx "Match EPG": pick the guide channel when the tvg-id is wrong.
                Button(action: match) {
                    Image(systemName: "link")
                        .font(.system(size: BP.px(16), weight: .bold))
                        .foregroundStyle(channel.epgMatch != nil ? BP.accent : BP.inkMuted)
                        .frame(width: BP.px(56), height: BP.px(56))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
                .accessibilityLabel(T("Match EPG"))
            }
        }
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static func time(_ ms: Double) -> String { clock.string(from: Date(timeIntervalSince1970: ms / 1000)) }
    static func range(_ p: LiveModel.Program) -> String { "\(time(p.startMs)) – \(time(p.endMs))" }
}

/// bp-live-sources / bp-live-setup: add an M3U, middleware or Xtream URL, an optional EPG URL,
/// switch between sources, remove one.
struct LiveSourcesSheet: View {
    @ObservedObject var model: LiveModel
    let firstRun: Bool
    let dismiss: () -> Void
    /// bp-live-sources seeds the ring on the active source; Settings opens on the form (bp-settings
    /// renders BpLiveSetup itself).
    var seedActive = true
    @State private var name = ""
    @State private var url = ""
    @State private var epg = ""
    @State private var kind = "m3u"
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    /// source-picker.tsx confirmDialog('Remove playlist "{name}"?') before a source goes.
    @State private var removing: LiveModel.Playlist?
    @FocusState private var focus: String?
    /// The source just removed and its neighbour: applied once the sources are read again (the
    /// channels of the source shown next may still be loading, which can take a while).
    private struct AfterRemove { let removed: String; let neighbour: String? }
    @State private var afterRemove: AfterRemove?

    /// bp-live-setup complete(): what each kind needs before Add is offered.
    private var ready: Bool {
        switch kind {
        case "xtream": return server.trimmingCharacters(in: .whitespaces).count >= 4 && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case "epg": return epg.trimmingCharacters(in: .whitespaces).count >= 8
        default: return url.trimmingCharacters(in: .whitespaces).count >= 8
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !firstRun { BP.canvas.ignoresSafeArea() }
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text(firstRun ? "Live TV" : "Sources").font(BP.display(36)).foregroundStyle(BP.ink)
                    BPNote(text: "Paste an M3U or M3U8 playlist URL, an IPTV middleware address, or an Xtream Codes login URL (get.php with username and password). Xtream guides are found automatically.")
                    // bp-live-setup kind picker: M3U link, Xtream Codes login, or guide data only.
                    HStack(spacing: BP.px(8)) {
                        ForEach([("m3u", "M3U playlist"), ("xtream", "Xtream Codes"), ("epg", "Guide data only")], id: \.0) { k, label in
                            Button(T(label)) { kind = k; error = nil }.buttonStyle(BPActionStyle(primary: kind == k)).bpSelected(kind == k)
                        }
                    }
                    BPField(label: "Name", placeholder: "My provider", text: $name)
                    if kind == "xtream" {
                        BPField(label: "Server", placeholder: "http://host:port", text: $server, keyboard: .URL)
                        BPField(label: "Username", placeholder: "Username", text: $username)
                        BPField(label: "Password", placeholder: "Password", text: $password, secure: true)
                    } else if kind == "m3u" {
                        BPField(label: "Playlist address", placeholder: "https://…/playlist.m3u", text: $url, keyboard: .URL)
                        BPField(label: "EPG URL (optional)", placeholder: "https://…/guide.xml.gz", text: $epg, keyboard: .URL)
                    } else {
                        BPField(label: "XMLTV address", placeholder: "https://…/guide.xml.gz", text: $epg, keyboard: .URL)
                    }
                    HStack(spacing: BP.px(12)) {
                        Button(busy ? "Adding…" : "Add source") {
                            guard !busy, ready else { return }
                            busy = true
                            Task {
                                // An M3U always goes through addPlaylist
                                // (detectProviderShape: http(s) check, Xtream login URLs, middleware).
                                // A server typed under Xtream before switching to M3U sent it through
                                // the unchecked structured path instead.
                                let failure: String? = kind == "m3u"
                                    ? await model.add(name: name, url: url, epgUrl: epg)
                                    : await model.add(kind: kind, name: name, url: url, epgUrl: epg, server: server, username: username, password: password)
                                error = failure
                                if failure == nil {
                                    // busy stays on while the sheet goes (a second press added the source
                                    // twice). First run has no sheet to close: a channel source has already
                                    // replaced the form (the sources were re-read), a guide-only one keeps it.
                                    name = ""; url = ""; epg = ""; server = ""; username = ""; password = ""
                                    if firstRun { busy = false }
                                    dismiss()
                                } else {
                                    busy = false
                                }
                            }
                        }
                        .buttonStyle(BPActionStyle(primary: true, busy: busy)).disabled(!ready)
                        if !firstRun { Button("Close") { dismiss() }.buttonStyle(BPActionStyle()).focused($focus, equals: "close") }
                    }
                    if let e = error ?? model.error { BPNote(text: e, tone: BP.danger) }
                }
                .frame(maxWidth: BP.px(560))
                if !model.allSources.isEmpty {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        Text("Your sources").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                        ForEach(model.allSources) { pl in
                            let guideOnly = pl.kind == "epg"
                            let detail: String = guideOnly
                                ? T("Guide data only") + " · " + (pl.epgUrl ?? pl.url)
                                : (pl.epgUrl.map { T("Guide: %@", $0) } ?? T("No guide URL"))
                            HStack(spacing: BP.px(8)) {
                                // A guide-only source has no channels to show: it backs every source's guide.
                                Button(pl.name) {
                                    // bp-live-sources onPick + onClose: the sheet closes now and the
                                    // source loads behind it. It waited for the
                                    // whole playlist, and a late close shut a Sources sheet opened again.
                                    let id = pl.id
                                    dismiss()
                                    Task { await model.select(id) }
                                }
                                .buttonStyle(BPActionStyle(primary: model.selectedPlaylist == pl.id)).bpSelected(model.selectedPlaylist == pl.id)
                                .disabled(guideOnly)
                                .focused($focus, equals: "src:\(pl.id)")
                                Button("Remove") { removing = pl }.buttonStyle(BPActionStyle())
                                    .focused($focus, equals: "rm:\(pl.id)")
                            }
                            Text(detail).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        if model.selectedPlaylist != nil {
                            Button("Use the EPG URL above for the selected source") {
                                let value = epg
                                Task { await model.setEpgUrl(value); epg = "" }
                            }
                            .buttonStyle(BPActionStyle()).disabled(kind == "xtream" || epg.count < 8)
                            Button("Refresh channels and guide") {
                                dismiss()
                                Task { await model.loadChannels(force: true) }
                            }
                            .buttonStyle(BPActionStyle())
                        }
                    }
                    .frame(maxWidth: BP.px(520))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
        }
        .focusSection()
        .alert(T("Remove playlist \"%@\"?", removing?.name ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { pl in
            Button("Remove", role: .destructive) {
                let id = pl.id
                // The row goes with the Remove the alert hands the ring back to:
                // it lands on the Remove of the source now in its place (the next, else the one
                // before), or on Close when none is left, instead of wherever tvOS chose.
                let list: [LiveModel.Playlist] = model.allSources
                var neighbour: String?
                if let i = list.firstIndex(where: { $0.id == id }) {
                    if i + 1 < list.count { neighbour = list[i + 1].id } else if i > 0 { neighbour = list[i - 1].id }
                }
                afterRemove = AfterRemove(removed: id, neighbour: neighbour)
                Task { await model.remove(id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.allSources.map(\.id)) { _, ids in
            guard let after = afterRemove, !ids.contains(after.removed) else { return }
            afterRemove = nil
            // After the alert has gone: the sources can be read again before it finishes
            // dismissing, and a focus set under a presented alert is dropped.
            var target: String?
            if let n = after.neighbour, ids.contains(n) { target = "rm:" + n } else if !firstRun { target = "close" }
            guard let target else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = target }
        }
        .task {
            guard !firstRun else { return }
            if !model.sourcesRead { await model.load() }
            // bp-live-sources: the ring starts on the active source (it started on the kind picker).
            guard seedActive, let id = model.selectedPlaylist else { return }
            try? await Task.sleep(for: .milliseconds(150))
            if focus == nil { focus = "src:\(id)" }
        }
    }
}

/// Settings' Live TV row (bp-settings.tsx pane "live" renders BpLiveSetup in place): the Sources
/// sheet over its own model. The row used to leave Settings for the
/// Live TV tab, where a viewer with sources landed on the guide, not on the form.
struct LiveSourcesCover: View {
    let dismiss: () -> Void
    @StateObject private var model = LiveModel(sourcesOnly: true)

    var body: some View {
        LiveSourcesSheet(model: model, firstRun: false, dismiss: dismiss, seedActive: false)
    }
}
