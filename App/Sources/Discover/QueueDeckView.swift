import SwiftUI


struct QueueDeckView: View {
    @StateObject private var model = QueueDeckModel()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @State private var detail: DetailTarget?
    /// bp-queue.tsx `confirming`: the title Not interested would hide for good.
    @State private var confirmBlock: QueueDeckModel.Entry?
    @FocusState private var focus: String?
    struct DetailTarget: Identifiable { var meta: Meta; var autoPlay: Bool; var id: String { meta.id } }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BP.void_.ignoresSafeArea()
            if let c = model.current {
                RemoteImage(url: c.meta.background ?? c.meta.poster).ignoresSafeArea().id(c.id)
                    .transition(.opacity)
                    .opacity(railFocused ? 0.6 : 1)   // bp-queue-stage dimmed={zone === "rail"}
                    .accessibilityHidden(true)
                LinearGradient(colors: [BP.void_.opacity(0.2), BP.void_.opacity(0.75), BP.void_.opacity(0.97)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                LinearGradient(colors: [BP.void_.opacity(0.9), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5)).ignoresSafeArea()
                    .flipsForRightToLeftLayoutDirection(true)   // bp-tokens.ts --bp-scrim-side under rtl
            }
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text("Discovery Queue").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.accent)
                if let c = model.current {
                    // bp-queue.tsx queue-deck cell: the one focusable spot where Left and Right step the
                    // deck (never a tile, so no lift or ring); Select plays like the rail's Play now.
                    Button { detail = DetailTarget(meta: c.meta, autoPlay: true) } label: {
                        HStack(alignment: .bottom, spacing: BP.px(24)) {
                            RemoteImage(url: c.meta.poster).frame(width: BP.px(180), height: BP.px(270))
                                .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                // bp-queue.tsx BpQueuePosition tag={t(copy.shown.tag)}: pool tags are English keys.
                                if !c.tag.isEmpty { Text(T(c.tag)).font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkMuted) }
                                Text(c.meta.name).font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(2)
                                Text(c.meta.facts).font(BP.sans(14, .medium)).foregroundStyle(BP.inkMuted)
                                if let d = c.meta.description, !d.isEmpty { Text(d).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: BP.px(900), alignment: .leading) }
                                Text("\(model.index + 1) of \(model.entries.count) · Left and Right step through the deck").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(QueueDeckCellStyle())
                    .focused($focus, equals: "deck")
                    // The visible line says "N of M" too; without it here VoiceOver loses the deck
                    // position that Left/Right steps through.
                    .accessibilityLabel(Text(verbatim: c.meta.name + ", " + T("%lld of %lld", model.index + 1, model.entries.count)))
                    HStack(spacing: BP.px(10)) {
                        chip("Play now", "play.fill") { detail = DetailTarget(meta: c.meta, autoPlay: true) }
                        chip(model.saved.contains(c.id) ? "Saved" : "Save", model.saved.contains(c.id) ? "bookmark.fill" : "bookmark", key: "save") { Task { await model.toggleSave() } }
                        chip("Details", "info.circle") { detail = DetailTarget(meta: c.meta, autoPlay: false) }
                        chip("Skip", "forward.end") { Task { await model.snooze() } }
                        chip("Not interested", "hand.thumbsdown") { confirmBlock = c }
                        chip("Back to Discover", "chevron.backward") { dismiss() }
                    }
                    .focusSection()
                    Text("Skip hides it for two weeks · Not interested never shows it again").font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                } else {
                    Text(T(emptyTitle)).font(BP.display(34)).foregroundStyle(BP.ink)
                    Text(T(emptyBlurb)).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                    HStack(spacing: BP.px(10)) {
                        chip("Back to Discover", "chevron.backward") { dismiss() }
                        if model.status == "nokey" { chip("Open Settings", "gearshape") { dismiss(); app.room = .settings } }
                    }
                    .focusSection()
                }
            }
            .padding(BP.gutter).padding(.bottom, BP.px(30))
        }
        .animation(BP.easeFast, value: model.index)
        .onMoveCommand { dir in
            // bp-queue.tsx: forward is the reading direction (Left steps forward under rtl).
            // Only while the deck cell holds the ring (setBpQueueKeyHandler: zone === "deck"); on the
            // action chips Left and Right move along the chips.
            guard focus == "deck", dir == .left || dir == .right else { return }
            model.step((dir == .right) != L10n.isRTL ? 1 : -1)
        }
        .onExitCommand { dismiss() }
        .task {
            // Seed focus on the first open only: the task runs again whenever a
            // Details / Play now cover closes, and threw the ring from the chip used back to the deck
            // (bp-queue restores the ring by data-bp-restore-key).
            guard await model.open() else { return }
            focus = model.current == nil ? "Back to Discover" : "deck"
        }
        // bp-queue-rail useInWatchlist: Save / Saved for the card on screen.
        .task(id: model.current?.id) { await model.readSaved() }
        // bp-queue.tsx recoverBpFocus: the last pick skipped or hidden takes the deck and the rail
        // with it; the ring goes to Back to Discover instead of nowhere.
        .onChange(of: model.current == nil) { _, empty in
            if empty, model.status != "loading" { focus = "Back to Discover" }
        }
        .alert(Text(T("Hide this permanently?")), isPresented: Binding(get: { confirmBlock != nil }, set: { if !$0 { confirmBlock = nil } }), presenting: confirmBlock) { c in
            Button(T("Not interested"), role: .destructive) { Task { await model.block(c.id) } }
            Button(T("Keep"), role: .cancel) {}
        } message: { c in
            Text(T("%@ will not come back in the Discovery Queue.", c.meta.name))
        }
        .fullScreenCover(item: $detail) { t in DetailView(meta: t.meta, autoPlay: t.autoPlay) }
    }

    /// A rail chip holds the ring (bp-queue zone "rail"): the art is veiled.
    private var railFocused: Bool { focus != nil && focus != "deck" }

    private var emptyTitle: String { model.status == "loading" ? "Building tonight's queue…" : model.status == "empty" ? "Nothing left in today's picks" : "Discovery Queue" }
    private var emptyBlurb: String {
        switch model.status {
        case "nokey": return "Add a TMDB key in Settings to unlock the full discovery feed."
        case "unreachable": return "No picks loaded. TMDB might be unreachable."
        case "empty": return "Come back tomorrow, or clear what you skipped in Settings."
        default: return ""
        }
    }

    /// `key` names the focus spot when the label changes under the ring (Save / Saved).
    private func chip(_ label: String, _ icon: String, key: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(T(label), systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: label == "Play now"))
            .focused($focus, equals: key ?? label)
    }
}

/// The deck cell draws nothing of its own: a custom style also keeps tvOS's system lift off it.
private struct QueueDeckCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
