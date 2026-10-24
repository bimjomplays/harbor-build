import SwiftUI

/// bp-sports-addon-parts: the addon mark, a title and a sub line in one wide tile.
struct SportsAddonTile: View {
    let logo: String?
    let title: String
    let sub: String
    var icon: String = "powerplug"
    var body: some View {
        HStack(spacing: BP.px(12)) {
            Group {
                if let logo, !logo.isEmpty {
                    RemoteImage(url: logo, contentMode: .fit)
                } else {
                    Image(systemName: icon).font(.system(size: BP.px(20), weight: .semibold)).foregroundStyle(BP.inkMuted).accessibilityHidden(true)
                }
            }
            .frame(width: BP.px(44), height: BP.px(44))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            VStack(alignment: .leading, spacing: BP.px(3)) {
                Text(title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                Text(sub).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(12))
        .frame(width: BP.px(380), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}

/// bp-sports-addon-panel (+ -listings, -streams, -play): addon listings for a game, a listing's
/// streams, and the pick. A direct link plays live; an external page goes to the phone (tvOS has
/// no browser, where upstream calls openUrl); a torrent or catalogue title hands off to the
/// regular stream list for that meta (upstream's BpStreams).
struct SportsAddonPanelView: View {
    let game: SportsModel.Game
    @ObservedObject var model: SportsEventModel
    let initial: SportsEventModel.AddonRow?
    let onPlay: (Play) -> Void
    let onClose: () -> Void

    typealias Play = SportsAddonPanelModel.Play
    typealias StreamRow = SportsAddonPanelModel.StreamRow
    typealias Streams = SportsAddonPanelModel.Streams
    typealias Outcome = SportsAddonPanelModel.Outcome
    typealias External = SportsAddonPanelModel.External
    private typealias Seat = SportsAddonPanelModel.Seat

    /// The panel's state and logic (App/Shared); `model` here is the event's.
    @StateObject private var panel: SportsAddonPanelModel
    @FocusState private var seat: Seat?

    init(game: SportsModel.Game, model: SportsEventModel, initial: SportsEventModel.AddonRow?,
         onPlay: @escaping (Play) -> Void, onClose: @escaping () -> Void) {
        self.game = game
        self.model = model
        self.initial = initial
        self.onPlay = onPlay
        self.onClose = onClose
        _panel = StateObject(wrappedValue: SportsAddonPanelModel(game: game, sports: model, initial: initial, onPlay: onPlay, onClose: onClose))
    }

    static func matchCopy(_ row: SportsEventModel.AddonRow) -> String { SportsAddonPanelModel.matchCopy(row) }

    var body: some View {
        let _ = panel.update(onPlay: onPlay, onClose: onClose)
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text(panel.picked == nil ? "Addon sources" : "Addon streams").font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.accent)
                Text(game.headline.isEmpty ? game.leagueLabel : game.headline).font(BP.display(32)).foregroundStyle(BP.ink).lineLimit(1)
                if model.addons?.failed == true { BPNote(text: "Some addons did not respond. Try again.", tone: BP.danger) }
                if let row = panel.picked { streamsView(row) } else { listingsView }
            }
            .frame(maxWidth: BP.px(1100), alignment: .leading)
            .padding(BP.gutter).padding(.top, BP.px(30))
        }
        .onExitCommand { panel.exitPressed() }
        // Its own covers (the phone link, the stream list) hide it too; they bring it back.
        .onAppear { panel.appeared() }
        .onDisappear { panel.disappeared() }
        .task {
            let ring = $seat
            panel.bindFocus(read: { ring.wrappedValue }, write: { ring.wrappedValue = $0 })
            panel.seedOnce()
        }
        .onChange(of: panel.seedKey) { _, _ in panel.seedFocus() }
        .fullScreenCover(item: $panel.external) { e in ExternalLinkView(url: e.url) { panel.external = nil } }
        .fullScreenCover(item: $panel.handoff) { meta in
            PlayPickerView(meta: meta, episode: nil) { _, resolved in panel.handoffPlayed(meta, resolved) }
        }
    }

    // bp-sports-addon-listings: matching listings, or every channel when browsing; a name filter; pages of 24.
    @ViewBuilder private var listingsView: some View {
        let shown = Array(panel.filtered.prefix(panel.limit))
        let more = panel.filtered.count - shown.count
        let note = model.addonsLoading ? "Matching installed addons…"
            : !(model.addons?.installed ?? false) ? "No installed addon offers a sports catalog yet."
            : model.matchingAddons.isEmpty && !panel.browse && panel.query.isEmpty ? "No matching addon listing yet. Browse every addon channel to look for the broadcast."
            : panel.filtered.isEmpty ? "No addon listing matches that name."
            : "Choose an addon source to see its streams."
        Text(T(note)).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
        HStack(spacing: BP.px(10)) {
            TextField("Channel or event name", text: $panel.query).frame(width: BP.px(420))
                .focused($seat, equals: .search)
                .onChange(of: panel.query) { _, _ in panel.limit = SportsAddonPanelModel.page }
            Button(panel.browse ? "Matching events" : "Browse addon channels") { panel.toggleBrowse() }.buttonStyle(BPActionStyle())
                .focused($seat, equals: .browse)
            Button("Refresh") { panel.refresh() }.buttonStyle(BPActionStyle(busy: model.addonsLoading))
                .focused($seat, equals: .refresh)
            Button("Close") { panel.close() }.buttonStyle(BPActionStyle())
                .focused($seat, equals: .close)
        }
        .focusSection()
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.fixed(BP.px(380)), spacing: BP.px(10)), GridItem(.fixed(BP.px(380)), spacing: BP.px(10))], alignment: .leading, spacing: BP.px(10)) {
                ForEach(shown) { row in
                    Button { panel.choose(row) } label: { SportsAddonTile(logo: row.addonLogo, title: row.name, sub: SportsAddonPanelModel.matchCopy(row)) }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        .focused($seat, equals: .listing(row.key))
                }
                if more > 0 {
                    Button { panel.moreChannels() } label: { SportsAddonTile(logo: nil, title: T("More addon channels (%lld left)", more), sub: "", icon: "ellipsis") }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        .focused($seat, equals: .more)
                }
            }
            .padding(.vertical, BP.px(8))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    // bp-sports-addon-streams: the listing, a status note, one tile per stream, Back.
    @ViewBuilder private func streamsView(_ row: SportsEventModel.AddonRow) -> some View {
        let note = panel.pending ? "Checking addon streams…"
            : panel.fault == "stream" ? "Could not start this stream. Choose another source."
            : panel.fault == "listing" ? "Could not load the streams for this addon listing."
            : panel.streams.isEmpty ? "No streams returned. The event may not be available yet."
            : ""
        SportsAddonTile(logo: row.addonLogo, title: row.name, sub: row.addonName)
        if !note.isEmpty { Text(T(note)).font(BP.sans(14)).foregroundStyle(panel.fault.isEmpty ? BP.inkMuted : BP.danger) }
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                ForEach(panel.streams) { st in
                    Button { panel.play(row, st) } label: {
                        HStack(spacing: BP.px(12)) {
                            if panel.playing == st.index { ProgressView().tint(BP.inkMuted) }
                            else { Image(systemName: st.external ? "arrow.up.right.square" : "play.fill").foregroundStyle(BP.inkMuted).accessibilityHidden(true) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(st.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                if !st.title.isEmpty { Text(st.title).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(2) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                        .frame(width: BP.px(780), alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .focused($seat, equals: .stream(st.index))
                    .disabled(panel.playing != nil && panel.playing != st.index)
                }
            }
            .padding(.vertical, BP.px(8))
        }
        .scrollClipDisabled()
        Button { panel.back() } label: { Label("Back", systemImage: "chevron.backward") }.buttonStyle(BPActionStyle())
            .focused($seat, equals: .back)
    }
}

/// A web page an addon points at: tvOS has no browser, so the phone opens it.
struct ExternalLinkView: View {
    let url: String
    let onClose: () -> Void
    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            VStack(spacing: BP.px(14)) {
                if let qr = QRCode.image(url) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(240), height: BP.px(240)).accessibilityLabel(Text(T("QR code")))
                        .padding(BP.px(10)).background(Color.white).clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                }
                Text("This source opens in a web browser. Scan to open it on your phone.").font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                Text(url).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(2).frame(maxWidth: BP.px(700))
                Button("Close") { onClose() }.buttonStyle(BPActionStyle(primary: true))
            }
            .padding(BP.gutter)
        }
        .onExitCommand { onClose() }
    }
}
