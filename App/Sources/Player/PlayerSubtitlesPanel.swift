import SwiftUI

/// bp-player-subtitles.tsx: the in-player Subtitles dialog. Four lanes (Tracks, Find more, Sync,
/// Look) under a header that says what is on and how far it is shifted. The labels, badges and
/// best-match order come from the engine (`subtitles.trackView`), which runs upstream's own
/// track-label / classification / best-match code. The tracks, Find more, offset and Look logic
/// lives in SubtitlesPanelModel (App/Shared/Player); this view draws it with the remote's focus ring.
struct PlayerSubtitlesPanel: View {
    let onClose: () -> Void
    typealias Lane = SubtitlesPanelModel.Lane
    typealias TrackRow = SubtitlesPanelModel.TrackRow
    typealias Found = SubtitlesPanelModel.Found
    typealias Preset = SubtitlesPanelModel.Preset

    @StateObject private var model: SubtitlesPanelModel
    private let controller: (any PlayerEngineControlling)?
    private let context: PlaybackContext?
    private let subDelay: Binding<Double>
    @FocusState private var focus: String?
    @ObservedObject private var settings = SettingsBridge.shared

    init(controller: (any PlayerEngineControlling)?, context: PlaybackContext?, title: String, subDelay: Binding<Double>, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.controller = controller
        self.context = context
        self.subDelay = subDelay
        _model = StateObject(wrappedValue: SubtitlesPanelModel(controller: controller, context: context, title: title, subDelay: subDelay))
    }

    var body: some View {
        // The model works from this pass's inputs: the engine can change under the dialog (retry, switch, a late start).
        let _ = model.refreshInputs(controller: controller, context: context, subDelay: subDelay)
        // A sheet docked at the right over a lightly dimmed
        // picture, instead of a near full-screen card over a 88 % black: the video stays in view.
        ZStack(alignment: .trailing) {
            LinearGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.7)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: BP.px(5)) {
                    Label("Subtitles", systemImage: "captions.bubble").font(BP.display(26)).foregroundStyle(BP.ink)
                    Text(model.headerLine).font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
                .padding(.top, BP.px(24))

                HStack(spacing: BP.px(8)) {
                    laneChip(.tracks, "Tracks", "captions.bubble")
                    laneChip(.find, "Find more", "magnifyingglass")
                    laneChip(.sync, "Sync", "timer")
                    laneChip(.style, "Look", "slider.horizontal.3")
                    Spacer(minLength: 0)
                    Button { onClose() } label: { Label("Close", systemImage: "xmark") }
                        .buttonStyle(PlayerChipStyle())
                        .focused($focus, equals: "close")
                }
                .padding(.vertical, BP.px(10))
                .focusSection()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        switch model.lane {
                        case .tracks: tracksLane
                        case .find: findLane
                        case .sync: syncLane
                        case .style: lookLane
                        }
                    }
                    .padding(.horizontal, BP.px(12))
                    // The first chip row's top was cut by the scroller's edge.
                    .padding(.top, BP.px(16)).padding(.bottom, BP.px(24))
                }
                // A full-width line (1.01 lift on ~1 640 pt, ring 9.5 pt out) reaches ~18 pt
                // past its sides; 10 pt of padding let the scroller's clip cut both sides of the ring.
                // More headroom inside, the scroller pulled out by the difference: the rows stay put.
                .padding(.horizontal, -BP.px(6))
                .focusSection()
            }
            .padding(.horizontal, BP.px(30))
            .frame(width: BP.px(700), alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(Color.black.opacity(0.45)))
            )
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .padding(.vertical, BP.px(28))
            .padding(.trailing, BP.px(28))
        }
        .onAppear {
            // The focus ring lives in this view (@FocusState); the model reads and moves it through the binding.
            let ring = $focus
            model.bindFocus(read: { ring.wrappedValue }, write: { ring.wrappedValue = $0 })
            model.appeared()
        }
        // The track poll restarts with a new engine (a reload under the dialog hands it one).
        .task(id: model.engineKey) { await model.pollTracks() }
        .onChange(of: model.lane) { model.laneChanged() }
    }

    // MARK: header + lanes

    private func laneChip(_ id: Lane, _ label: String, _ icon: String) -> some View {
        Button { model.lane = id } label: { Label(T(label), systemImage: icon) }
            .buttonStyle(PlayerChipStyle(on: model.lane == id)).bpSelected(model.lane == id)
            .focused($focus, equals: "lane-\(label)")
    }

    /// `id` names the focus target when the label alone is not unique (a stepper's − and +).
    private func chip(_ label: String, on: Bool = false, icon: String? = nil, id: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let icon { Label(T(label), systemImage: icon) } else { Text(T(label)) }
        }
        .buttonStyle(PlayerChipStyle(on: on))
        .focused($focus, equals: id ?? "chip-\(label)")
        .bpSelected(on)
    }

    private func note(_ text: String) -> some View {
        Text(T(text)).font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle).padding(.vertical, BP.px(4))
    }

    @ViewBuilder private var tracksLane: some View {
        PlayerChipRow {
            PlayerRowLabel(text: "Languages")
            // Focus ids that outlive the counts in the labels.
            chip(T("All languages") + " \(model.langTracks.count)", on: model.activeLang == SubtitlesPanelModel.all, id: "lang-all") { model.activeLang = SubtitlesPanelModel.all }
            ForEach(model.groups) { g in
                chip("\(g.display) \(g.count)", on: model.activeLang == g.id, id: "lang-\(g.id)") { model.activeLang = g.id }
            }
        }
        PlayerChipRow {
            PlayerRowLabel(text: "Filters")
            chip("All", on: model.source == "all") { model.source = "all" }
            chip("Embedded", on: model.source == "embedded") { model.source = "embedded" }
            chip("External", on: model.source == "external") { model.source = "external" }
            chip("Hide HI/SDH", on: model.hideHI) { model.hideHI.toggle() }
            chip("Forced only", on: model.forcedOnly) { model.forcedOnly.toggle() }
        }
        if let better = model.best, !better.selected {
            PlayerChipRow {
                PlayerRowLabel(text: "Better match")
                // The row goes once its track is on: the ring moves to that
                // track's line (it fell wherever the focus engine put it).
                chip(model.titleOf(better), id: "better") {
                    model.select(better)
                    focus = "line-\(better.id)"
                }
            }
        }
        let noneOn = !model.tracks.contains { $0.selected }
        Button { model.select(nil) } label: {
            PlayerLineLabel(icon: noneOn ? "checkmark" : "captions.bubble.fill", title: T("No subtitles"))
        }
        .buttonStyle(PlayerLineStyle(on: noneOn))
        .focused($focus, equals: "line-off")
        .bpSelected(noneOn)
        ForEach(model.visible) { t in trackLine(t) }
        if model.visible.isEmpty {
            note("No tracks match these filters. Try toggling HI/SDH or Forced.")
        }
        if !model.mpvExtras {
            note("On the AVPlayer engine, a second subtitle has to be one added from Find more.")
        }
    }

    private func trackLine(_ t: MPVPlayerController.Track) -> some View {
        var badges = model.row(t)?.tags ?? []
        if model.best?.id == t.id { badges.insert(T("Best match"), at: 0) }
        return HStack(spacing: BP.px(10)) {
            Button { model.select(t) } label: {
                PlayerLineLabel(icon: t.selected ? "checkmark" : "captions.bubble", title: model.titleOf(t), detail: model.row(t)?.detail, badges: badges)
            }
            .buttonStyle(PlayerLineStyle(on: t.selected))
            .focused($focus, equals: "line-\(t.id)")
            .bpSelected(t.selected)
            // setSecondarySub: a second track under the first, or off again (on AVPlayer, added tracks only).
            if model.mpvExtras || t.external {
                Button { model.toggleSecondary(t) } label: { Label("2nd", systemImage: "character.bubble") }
                    .buttonStyle(PlayerChipStyle(on: t.secondary))
                    .focused($focus, equals: "second-\(t.id)")
                    .bpSelected(t.secondary)
            }
        }
    }

    // MARK: Find more (bp-subtitle-find.tsx)

    @ViewBuilder private var findLane: some View {
        BPField(label: "Search", placeholder: "Search any show or movie", text: $model.query)
            .frame(maxWidth: BP.px(620))
            .onSubmit { Task { await model.submit() } }
        PlayerChipRow {
            chip(model.searching ? "Searching…" : "Search", icon: "magnifyingglass", id: "chip-Search") { Task { await model.submit() } }
            if model.override {
                chip("Back to what's playing") { model.backToPlaying() }
            }
            if let t = model.target, t.type == "series" {
                stepper("Season", value: t.season ?? 1, reset: { Task { await model.run(t) } }) { d in model.changeEp(season: max(1, (t.season ?? 1) + d), episode: t.episode) }
                stepper("Episode", value: t.episode ?? 1, reset: { Task { await model.run(t) } }) { d in model.changeEp(season: t.season, episode: max(1, (t.episode ?? 1) + d)) }
            }
            chip("Hide HI/SDH", on: model.hideHI) { model.hideHI.toggle() }
            chip("Forced only", on: model.forcedOnly) { model.forcedOnly.toggle() }
        }
        findResults
    }

    @ViewBuilder private var findResults: some View {
        if model.searching { note("Searching…") }
        if let findNote = model.findNote { note(findNote) }
        let list = model.flat
        if model.results != nil, list.isEmpty, !model.searching {
            note(model.tooNew ? "Too new. Subtitles haven't been published yet." : "No subtitles found. Try another title above, or adjust the season and episode.")
        }
        // Keyed by id and URL like bp-subtitle-find (`${source}:${id}:${url}`):
        // two addons answering with the same id drew one row twice and shared its focus target.
        ForEach(Array(list.prefix(model.limit).enumerated()), id: \.element.key) { i, r in
            if i == 0 || list[i - 1].langName != r.langName { PlayerRowLabel(text: r.langName).padding(.top, BP.px(6)) }
            let isAdded = model.added.contains(r.url)
            Button {
                Task { await model.add(r) }
            } label: {
                PlayerLineLabel(icon: isAdded ? "checkmark" : "plus", title: r.title, detail: r.detail, badges: isAdded ? [T("Added")] + r.tags : r.tags)
            }
            .buttonStyle(PlayerLineStyle())
            .focused($focus, equals: "find-\(r.key)")
        }
        if list.count > model.limit {
            PlayerChipRow {
                chip(T("Show %lld more", list.count - model.limit), id: "find-more") { model.showMore() }
            }
        }
    }

    /// bp-subtitle-parts.tsx Stepper: − / value (resets) / +.
    private func stepper(_ label: String, value: Int, reset: @escaping () -> Void, step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: BP.px(8)) {
            PlayerRowLabel(text: label)
            // bp-subtitle-parts.tsx Stepper: aria-label t("Decrease {name}") / t("Reset {name}") /
            // t("Increase {name}") — a bare glyph or number is not a name on its own.
            chip("−", id: "dec-\(label)", action: { step(-1) })
                .accessibilityLabel(Text(T("Decrease %@", T(label))))
            chip("\(value)", id: "val-\(label)", action: reset)
                .accessibilityLabel(Text(T("Reset %@", T(label))))
            chip("+", id: "inc-\(label)", action: { step(1) })
                .accessibilityLabel(Text(T("Increase %@", T(label))))
        }
    }

    // MARK: Sync (bp-subtitle-tune.tsx BpSubtitleSync, manual offset)

    @ViewBuilder private var syncLane: some View {
        PlayerChipRow {
            PlayerRowLabel(text: "Manual offset")
            ForEach([-1.0, -0.1, 0.1, 1.0], id: \.self) { step in
                chip("\(step > 0 ? "+" : "")\(String(format: "%.1f", step))s") { model.nudgeDelay(by: step) }
            }
            Text(model.offsetLabel).font(BP.display(30)).foregroundStyle(BP.ink).monospacedDigit()
                .padding(.horizontal, BP.px(10))
            chip("Reset") { model.setDelay(0) }
        }
        note("Subtitles late? Nudge plus. Early? Nudge minus.")
    }

    // MARK: Look (bp-subtitle-tune.tsx BpSubtitleLook)

    @ViewBuilder private var lookLane: some View {
        let s = settings.slice
        if !model.presets.isEmpty {
            PlayerChipRow {
                PlayerRowLabel(text: "Presets")
                ForEach(model.presets) { p in chip(p.name) { model.update(p.values) } }
            }
        }
        PlayerChipRow {
            let size: Double = model.lookDraft["subFontSize"] ?? s.subFontSize ?? 32
            let height: Double = model.lookDraft["subMarginY"] ?? s.subMarginY ?? 12
            let opacity: Double = model.lookDraft["subOpacity"] ?? s.subOpacity ?? 1
            stepper("Size", value: Int(size), reset: { model.update(["subFontSize": .number(32)]) }) { d in
                model.stepLook("subFontSize", model.clamp(size + Double(d) * 4, 16, 120))
            }
            stepper("Height", value: Int(height), reset: { model.update(["subMarginY": .number(10)]) }) { d in
                model.stepLook("subMarginY", model.clamp(height + Double(d) * 2, 0, 100))
            }
            PlayerRowLabel(text: "Opacity")
            chip("−", id: "dec-Opacity") { model.stepLook("subOpacity", model.clamp(((opacity - 0.1) * 100).rounded() / 100, 0.1, 1)) }
                .accessibilityLabel(Text(T("Decrease %@", T("Opacity"))))
            chip("\(Int((opacity * 100).rounded()))%", id: "val-Opacity") { model.update(["subOpacity": .number(1)]) }
                .accessibilityLabel(Text(T("Reset %@", T("Opacity"))))
            chip("+", id: "inc-Opacity") { model.stepLook("subOpacity", model.clamp(((opacity + 0.1) * 100).rounded() / 100, 0.1, 1)) }
                .accessibilityLabel(Text(T("Increase %@", T("Opacity"))))
        }
        PlayerChipRow {
            let style = s.subStyle ?? "shadow"
            PlayerRowLabel(text: "Backing")
            chip("Shadow", on: style == "shadow") { model.update(["subStyle": .string("shadow")]) }
            chip("Outline", on: style == "outline") { model.update(["subStyle": .string("outline")]) }
            chip("Box", on: style == "box") { model.update(["subStyle": .string("box")]) }
            chip("Bold", on: s.subBold ?? false) { model.update(["subBold": .bool(!(s.subBold ?? false))]) }
        }
        sample(s)
    }

    /// The sample approximates mpv; the colours are the viewer's own values, written as-is.
    private func sample(_ s: SettingsBridge.Slice) -> some View {
        let style = s.subStyle ?? "shadow"
        let outline = style == "outline" ? hexColor(s.subBorderColor, .black) : Color.clear
        let edge = CGFloat(max(1, min(s.subBorderSize ?? 2, 4)))
        return HStack {
            Spacer(minLength: 0)
            Text("This is how your subtitles will look.")
                .font(.custom((s.subBold ?? false) ? "Switzer-Bold" : "Switzer-Semibold", size: max(BP.px(16), CGFloat(s.subFontSize ?? 32))))
                .multilineTextAlignment(.center)
                .foregroundStyle(hexColor(s.subFontColor, .white))
                .shadow(color: outline, radius: 0, x: edge, y: 0)
                .shadow(color: outline, radius: 0, x: -edge, y: 0)
                .shadow(color: outline, radius: 0, x: 0, y: edge)
                .shadow(color: outline, radius: 0, x: 0, y: -edge)
                .shadow(color: style == "shadow" ? Color.black.opacity(0.9) : Color.clear, radius: 5, x: 0, y: 2)
                .padding(.horizontal, style == "box" ? BP.px(10) : 0)
                .padding(.vertical, style == "box" ? BP.px(4) : 0)
                .background(style == "box" ? hexColor(s.subBoxColor, .black).opacity(s.subBoxOpacity ?? 0.6) : Color.clear)
                .opacity(s.subOpacity ?? 1)
            Spacer(minLength: 0)
        }
        .padding(BP.px(28))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.void_))
        .padding(.top, BP.px(8))
    }

    private func hexColor(_ hex: String?, _ fallback: Color) -> Color {
        var h = (hex ?? "").trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return fallback }
        return Color(hex: v)
    }
}
