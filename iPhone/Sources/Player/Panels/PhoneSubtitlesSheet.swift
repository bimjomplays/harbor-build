import SwiftUI

/// The in-player Subtitles sheet (bp-player-subtitles.tsx, PlayerSubtitlesPanel's phone twin): the same
/// SubtitlesPanelModel the TV draws, in four lanes: the tracks, Find more (addon and provider subtitles),
/// Sync (the delay) and Look (size, height, opacity, style). A pick plays at once and the sheet stays
/// up; the position is the engine's own and is not touched.
struct PhoneSubtitlesSheet: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject private var settings = SettingsBridge.shared
    let onClose: () -> Void
    @StateObject private var model: SubtitlesPanelModel

    init(session: PlayerSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _model = StateObject(wrappedValue: SubtitlesPanelModel(controller: session.controller, context: session.context,
                                                               title: session.title, subDelay: Self.delay(of: session)))
    }

    /// The session's subtitle delay, which the model reads and writes.
    private static func delay(of session: PlayerSession) -> Binding<Double> {
        Binding(get: { [weak session] in session?.subDelay ?? 0 }, set: { [weak session] in session?.subDelay = $0 })
    }

    var body: some View {
        // The engine can change under the sheet (a retry): the model reads this pass's.
        let _ = model.refreshInputs(controller: session.controller, context: session.context, subDelay: Self.delay(of: session))
        PhoneSheetFrame(panel: .subtitles, line: model.headerLine, onClose: onClose) {
            lanes
            switch model.lane {
            case .tracks: tracksLane
            case .find: findLane
            case .sync: syncLane
            case .style: lookLane
            }
        }
        .task(id: model.engineKey) { await model.pollTracks() }
        .onAppear { model.appeared() }
    }

    // MARK: lanes

    private var lanes: some View {
        PhoneFlowRow(spacing: 8, lineSpacing: 8) {
            lane(.tracks, T("Tracks"), "tracks")
            lane(.find, T("Find more"), "find")
            lane(.sync, T("Sync"), "sync")
            lane(.style, T("Look"), "look")
        }
    }

    private func lane(_ l: SubtitlesPanelModel.Lane, _ title: String, _ id: String) -> some View {
        PhoneOptionChip(id: "panel-subs-lane-" + id, title: title, selected: model.lane == l) {
            model.lane = l
            model.laneChanged()
        }
    }

    // MARK: Tracks

    @ViewBuilder private var tracksLane: some View {
        let offOn: Bool = !model.tracks.contains { $0.selected }
        PhonePanelRow(id: "panel-subs-off", icon: "captions.bubble", title: T("No subtitles"), selected: offOn) { model.select(nil) }
        if model.groups.count > 1 {
            PhoneFlowRow(spacing: 8, lineSpacing: 8) {
                PhoneOptionChip(id: "panel-subs-lang-all", title: T("All languages"), selected: model.activeLang == SubtitlesPanelModel.all) {
                    model.activeLang = SubtitlesPanelModel.all
                }
                ForEach(model.groups) { g in
                    PhoneOptionChip(id: "panel-subs-lang-\(g.id)", title: "\(g.display) \(g.count)", selected: model.activeLang == g.id) {
                        model.activeLang = g.id
                    }
                }
            }
        }
        PhoneFlowRow(spacing: 8, lineSpacing: 8) {
            PhoneOptionChip(id: "panel-subs-source-all", title: T("All sources"), selected: model.source == "all") { model.source = "all" }
            PhoneOptionChip(id: "panel-subs-source-embedded", title: T("Embedded"), selected: model.source == "embedded") { model.source = "embedded" }
            PhoneOptionChip(id: "panel-subs-source-external", title: T("Added"), selected: model.source == "external") { model.source = "external" }
            PhoneOptionChip(id: "panel-subs-hide-hi", title: T("Hide SDH"), selected: model.hideHI) { model.hideHI.toggle() }
            PhoneOptionChip(id: "panel-subs-forced", title: T("Forced only"), selected: model.forcedOnly) { model.forcedOnly.toggle() }
        }
        let best: Int? = model.best?.id
        ForEach(model.visible, id: \.id) { t in
            let r = model.row(t)
            PhonePanelRow(id: "panel-subs-track-\(t.id)", icon: "captions.bubble", title: model.titleOf(t),
                          detail: r?.detail ?? "",
                          badges: (best == t.id ? [T("Best match")] : []) + (r?.tags ?? []),
                          selected: t.selected) { model.select(t) }
        }
    }

    // MARK: Find more

    @ViewBuilder private var findLane: some View {
        HStack(spacing: 8) {
            TextField(T("Search any show or movie"), text: $model.query)
                .font(PhoneTheme.sans(16, .medium, relativeTo: .body)).foregroundStyle(BP.ink)
                .submitLabel(.search)
                .onSubmit { Task { await model.submit() } }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.panel))
                .accessibilityIdentifier("panel-subs-query")
            PhoneOptionChip(id: "panel-subs-search", title: T("Search"), systemImage: "magnifyingglass") { Task { await model.submit() } }
        }
        if model.override {
            PhoneOptionChip(id: "panel-subs-back", title: T("Back to what's playing"), systemImage: "arrow.uturn.backward") { model.backToPlaying() }
        }
        PhoneFlowRow(spacing: 8, lineSpacing: 8) {
            PhoneOptionChip(id: "panel-subs-find-hide-hi", title: T("Hide SDH"), selected: model.hideHI) { model.hideHI.toggle() }
            PhoneOptionChip(id: "panel-subs-find-forced", title: T("Forced only"), selected: model.forcedOnly) { model.forcedOnly.toggle() }
        }
        if model.searching {
            ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, minHeight: 60)
                .accessibilityIdentifier("panel-subs-searching")
        }
        if let note = model.findNote { PhoneNote(text: note, tone: BP.danger) }
        if model.tooNew { PhoneNote(text: T("Too new. Subtitles haven't been published yet.")) }
        let all = model.flat
        ForEach(all.prefix(model.limit), id: \.key) { r in
            let got: Bool = model.added.contains(r.url)
            PhonePanelRow(id: "panel-subs-found-\(r.key)", icon: "plus.circle", title: r.title,
                          detail: [r.langName, r.detail].filter { !$0.isEmpty }.joined(separator: " · "),
                          badges: [r.provider] + r.tags, selected: got) {
                Task { await model.add(r) }
            }
        }
        if all.count > model.limit {
            PhoneOptionChip(id: "panel-subs-more", title: T("Show %lld more", min(SubtitlesPanelModel.page, all.count - model.limit))) { model.showMore() }
        }
        if !model.searching, model.results != nil, all.isEmpty, model.findNote == nil {
            PhoneNote(text: T("No subtitles found. Try another title above, or adjust the season and episode."))
        }
    }

    // MARK: Sync

    @ViewBuilder private var syncLane: some View {
        Text(verbatim: model.offsetLabel)
            .font(PhoneTheme.sans(17, .semibold, relativeTo: .body)).monospacedDigit().foregroundStyle(BP.ink)
            .accessibilityIdentifier("panel-subs-delay-value")
        PhoneFlowRow(spacing: 8, lineSpacing: 8) {
            ForEach([-0.5, -0.1, 0.1, 0.5], id: \.self) { step in
                PhoneOptionChip(id: "panel-subs-delay-" + String(format: "%+.1f", step), title: String(format: "%+.1fs", step)) {
                    model.nudgeDelay(by: step)
                }
            }
            PhoneOptionChip(id: "panel-subs-delay-reset", title: T("Reset")) { model.setDelay(0) }
        }
    }

    // MARK: Look

    @ViewBuilder private var lookLane: some View {
        let s = settings.slice
        if !model.presets.isEmpty {
            PhoneSectionLabel(text: T("Presets"))
            PhoneFlowRow(spacing: 8, lineSpacing: 8) {
                ForEach(model.presets) { p in
                    PhoneOptionChip(id: "panel-subs-preset-\(p.id)", title: p.name) { model.update(p.values) }
                }
            }
        }
        let size: Double = model.lookDraft["subFontSize"] ?? s.subFontSize ?? 32
        let height: Double = model.lookDraft["subMarginY"] ?? s.subMarginY ?? 10
        let opacity: Double = model.lookDraft["subOpacity"] ?? s.subOpacity ?? 1
        stepper("size", T("Size"), "\(Int(size))",
                dec: { model.stepLook("subFontSize", model.clamp(size - 4, 16, 120)) },
                inc: { model.stepLook("subFontSize", model.clamp(size + 4, 16, 120)) },
                reset: { model.update(["subFontSize": .number(32)]) })
        stepper("height", T("Height"), "\(Int(height))",
                dec: { model.stepLook("subMarginY", model.clamp(height - 2, 0, 100)) },
                inc: { model.stepLook("subMarginY", model.clamp(height + 2, 0, 100)) },
                reset: { model.update(["subMarginY": .number(10)]) })
        stepper("opacity", T("Opacity"), "\(Int((opacity * 100).rounded()))%",
                dec: { model.stepLook("subOpacity", model.clamp(((opacity - 0.1) * 100).rounded() / 100, 0.1, 1)) },
                inc: { model.stepLook("subOpacity", model.clamp(((opacity + 0.1) * 100).rounded() / 100, 0.1, 1)) },
                reset: { model.update(["subOpacity": .number(1)]) })
        let style: String = s.subStyle ?? "shadow"
        PhoneFlowRow(spacing: 8, lineSpacing: 8) {
            PhoneOptionChip(id: "panel-subs-style-shadow", title: T("Shadow"), selected: style == "shadow") { model.update(["subStyle": .string("shadow")]) }
            PhoneOptionChip(id: "panel-subs-style-outline", title: T("Outline"), selected: style == "outline") { model.update(["subStyle": .string("outline")]) }
            PhoneOptionChip(id: "panel-subs-style-box", title: T("Box"), selected: style == "box") { model.update(["subStyle": .string("box")]) }
            PhoneOptionChip(id: "panel-subs-bold", title: T("Bold"), selected: s.subBold ?? false) {
                model.update(["subBold": .bool(!(s.subBold ?? false))])
            }
        }
    }

    /// bp-subtitle-parts.tsx Stepper: − value +, the value pressed puts the default back.
    private func stepper(_ id: String, _ name: String, _ value: String, dec: @escaping () -> Void,
                         inc: @escaping () -> Void, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: name).font(PhoneTheme.sans(15, .semibold, relativeTo: .body)).foregroundStyle(BP.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            PhoneOptionChip(id: "panel-subs-\(id)-dec", title: "−", label: T("Decrease %@", name), action: dec)
            PhoneOptionChip(id: "panel-subs-\(id)-value", title: value, label: T("Reset %@", name), action: reset)
                .frame(minWidth: 72)
            PhoneOptionChip(id: "panel-subs-\(id)-inc", title: "+", label: T("Increase %@", name), action: inc)
        }
    }
}
