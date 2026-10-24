import SwiftUI

/// The phone's play picker: a sheet that opens at half height and pulls up
/// to full, over the same PlayPickerModel and StreamsModel the TV's PlayPickerView drives. It lists
/// the streams in addon sections (or ranked, with the sort chip), the glass filter chips above them,
/// and stands the auto step or the subtitle step in for the list while either is up. A pick goes to
/// `PhonePlay.handOff(stream:)`, which closes the picker and opens the player.
///
/// Present it in a `.sheet`: `PhonePlayPicker(meta:video:dismiss:)`, `video` being upstream's
/// PlayEpisode as JSON (nil for a movie).
struct PhonePlayPicker: View {
    let meta: Meta
    let video: AnyJSON?
    let dismiss: () -> Void
    /// The in-player switcher: what plays now, and where a pick goes
    /// (the player swaps the stream in place) instead of the hand-off that opens a player. `dismiss`
    /// then closes only this sheet. nil/nil is the picker before the film.
    let switching: PlayingSource?
    private let onPicked: ((ScoredStream?, StreamsModel.Resolved) -> Void)?
    /// The search (StreamsModel) and the picker's state and logic, shared with the TV.
    @StateObject private var picker: PlayPickerModel
    private var model: StreamsModel { picker.model }
    @ObservedObject private var external = PhoneExternalPlay.shared
    @State private var detent: PresentationDetent = .medium
    typealias PickerDialog = PlayPickerModel.PickerDialog

    /// `autoPlay` is bp-detail's instantPlay (the auto step tries the best sources first);
    /// `subtitleStep` lets "Choose subtitles" stand between a pick by hand and the player when
    /// the subtitle-preselect setting is on.
    init(meta: Meta, video: AnyJSON?, dismiss: @escaping () -> Void,
         autoPlay: Bool = false, applyPreference: Bool = false, subtitleStep: Bool = true,
         switching: PlayingSource? = nil, onPicked: ((ScoredStream?, StreamsModel.Resolved) -> Void)? = nil) {
        self.meta = meta
        self.video = video
        self.dismiss = dismiss
        self.switching = switching
        self.onPicked = onPicked
        _picker = StateObject(wrappedValue: PlayPickerModel(
            meta: meta, episode: video, autoPlay: autoPlay, applyPreference: applyPreference,
            subtitleStep: subtitleStep, switching: switching,
            onPlay: onPicked ?? Self.handOff(meta: meta, video: video), onClose: switching == nil ? nil : dismiss))
    }

    private static func handOff(meta: Meta, video: AnyJSON?) -> (ScoredStream?, StreamsModel.Resolved) -> Void {
        { stream, resolved in
            PhonePlay.handOff(stream: PhonePlayStream(meta: meta, episode: video, stream: stream, resolved: resolved))
        }
    }

    var body: some View {
        // The model works from this pass's inputs, as on the TV.
        let _ = picker.update(switching: switching, onPlay: onPicked ?? Self.handOff(meta: meta, video: video),
                              onClose: switching == nil ? nil : dismiss, dismiss: dismiss)
        surface
            // Each dialog is a small sheet over the picker; covered, the picker keeps searching.
            .sheet(item: $picker.dialog) { d in
                dialogView(d)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentedCover("picker-dialog")
            }
            .task { await picker.runSearch() }
            .task { await picker.runAutoLoop() }
            .task { await picker.consumeStubEvent() }
            .onAppear {
                // No focus rings on a phone: the model's seed pass reads nil and writes nowhere.
                picker.bindFocus(row: (read: { nil }, write: { _ in }), chip: (read: { nil }, write: { _ in }))
                picker.appeared()
                external.refresh()
            }
            .onChange(of: model.streams.count) { _, n in picker.streamCountChanged(n) }
            .onChange(of: model.setup) { _, setup in picker.setupChanged(setup) }
            .onChange(of: picker.showAutoStep) { _, busy in picker.autoStepChanged(busy: busy) }
            .onChange(of: model.copiesLoaded) { _, loaded in if loaded { Task { await picker.applySourcePreference() } } }
            .onChange(of: model.phase) { _, phase in picker.phaseChanged(phase) }
            .onChange(of: picker.autoState) { _, state in picker.autoStateChanged(state) }
            .onChange(of: picker.dialog?.id) { _, id in if id != nil { PhoneFeedback.shared.warning() } }
            .onChange(of: picker.failedIds.count) { old, new in if new > old, !picker.autoFiring { PhoneFeedback.shared.failure() } }
            // The steps want the room: the sheet pulls up to full for either.
            .onChange(of: picker.preselect != nil || picker.showAutoStep, initial: true) { _, big in
                if big { withMotion(.snappy) { detent = .large } }
            }
            .onDisappear {
                picker.disappeared()
                if switching == nil { external.reset() }
            }
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentedCover(switching == nil ? "play-picker" : "player-sources")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(switching == nil ? "phone-picker" : "player-sheet-sources")
    }

    /// The subtitle step, the auto step, or the list.
    @ViewBuilder private var surface: some View {
        if let pending = picker.preselect {
            PhoneSubtitleStep(meta: meta, episode: video, imdbId: model.imdb?.id, imdbVerified: model.imdb?.verified ?? false,
                              streamRef: pending.resolved.streamRef, filename: pending.resolved.data?.filename,
                              onStart: { choice in picker.startPreselect(choice) }, onCancel: { picker.cancelPreselect() })
                .transition(.opacity)
        } else if picker.showAutoStep {
            PhonePickerAutoStep(meta: meta, episode: video, attemptIdx: picker.autoTried, resolving: picker.autoFiring,
                                p2p: model.p2pStarting, kid: ProfilesStore.shared.active?.kid != nil,
                                stubNotice: picker.stubNotice, onCancel: { picker.cancelAuto() })
                .transition(.opacity)
        } else {
            listSurface.transition(.opacity)
        }
    }

    // MARK: the list

    private var listSurface: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                header
                chips
                statusLines
                rows
                Color.clear.frame(height: 24)
            }
            .padding(.top, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: T("Play"))
                    .font(PhoneTheme.sans(12, .bold, relativeTo: .caption)).textCase(.uppercase).tracking(1)
                    .foregroundStyle(BP.accent)
                Text(verbatim: meta.name)
                    .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("picker-title")
                if let ep = picker.episodeLabel {
                    Text(verbatim: ep).font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline)).foregroundStyle(BP.inkMuted)
                        .accessibilityIdentifier("picker-episode")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                PhoneFeedback.shared.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(verbatim: T("Close")))
            .accessibilityIdentifier("picker-close")
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    /// bp-stream-chips: quality with counts, Cached, the addon, the facets, the preferred languages,
    /// the source, the saved filters, the sort, Clear filters and Refresh.
    private var chips: some View {
        ChipRow {
            ForEach(PlayPickerModel.qualities, id: \.0) { q in
                let n: Int = q.1.isEmpty ? picker.pool.count : picker.pool.filter { q.1.contains($0.resolution ?? "") }.count
                if n > 0 || q.0 == "All" {
                    // A String, not a literal: "%@ %lld" is a catalog entry some languages re-order.
                    GlassChip(title: T(q.0) + " \(n)", selected: picker.quality == q.0) {
                        PhoneFeedback.shared.selection()
                        withMotion(.snappy) { picker.quality = q.0 }
                    }
                }
            }
            if picker.cachedOnly || model.streams.contains(where: \.isCached) {
                let cachedCount: Int = model.streams.filter(\.isCached).count
                GlassChip(title: T("Cached") + " \(cachedCount)", systemImage: "bolt.fill", selected: picker.cachedOnly) {
                    PhoneFeedback.shared.selection()
                    withMotion(.snappy) { picker.cachedOnly.toggle() }
                }
            }
            if picker.addons.count > 1 {
                GlassChip(title: picker.addonFilter ?? T("All addons"), systemImage: "puzzlepiece.extension", selected: picker.addonFilter != nil) {
                    PhoneFeedback.shared.selection()
                    withMotion(.snappy) { picker.stepAddonFilter() }
                }
            }
            ForEach(PlayPickerModel.facets, id: \.key) { f in
                let opts = picker.facetOptions(f)
                if opts.count > 1 || picker.facet[f.key] != nil {
                    let title: String = picker.facet[f.key].map { v in "\(T(f.label)): \(v) \(opts.first { $0.0 == v }?.1 ?? 0)" } ?? T(f.label)
                    GlassChip(title: title, selected: picker.facet[f.key] != nil) {
                        PhoneFeedback.shared.selection()
                        withMotion(.snappy) { picker.stepFacet(f) }
                    }
                }
            }
            let langCount: Int = picker.langHiddenCount
            if langCount > 0 {
                GlassChip(title: (model.setup?.langLabel ?? "") + " \(langCount)", systemImage: "globe", selected: picker.langFilter) {
                    PhoneFeedback.shared.selection()
                    withMotion(.snappy) { picker.langFilter.toggle() }
                }
            }
            GlassChip(title: picker.sourceChipLabel, systemImage: "antenna.radiowaves.left.and.right",
                      selected: picker.sourceKind != "all" || model.streamMode != "both") {
                PhoneFeedback.shared.selection()
                withMotion(.snappy) { picker.nextSource() }
            }
            if !model.savedFilters.isEmpty {
                GlassChip(title: picker.filterChipLabel, systemImage: "line.3.horizontal.decrease", selected: model.activeFilterId != nil) {
                    PhoneFeedback.shared.selection()
                    picker.nextFilter()
                }
            }
            // An addon that ranks its own list owns the order: the chip stays, and does nothing.
            GlassChip(title: picker.sortChipLabel, systemImage: "arrow.up.arrow.down") {
                guard !model.addonRanked else { return }
                PhoneFeedback.shared.selection()
                withMotion(.snappy) { picker.toggleSort() }
            }
            .opacity(model.addonRanked ? 0.5 : 1)
            if picker.filtered {
                GlassChip(title: T("Clear filters"), systemImage: "xmark.circle") {
                    PhoneFeedback.shared.selection()
                    withMotion(.snappy) { picker.clearFilters() }
                }
            }
            GlassChip(title: T("Refresh"), systemImage: "arrow.clockwise") {
                PhoneFeedback.shared.tap()
                Task { await model.refresh() }
            }
        }
    }

    /// bp-streams header lines: the auto outcome, peers, the counts or the failure, a resolve error,
    /// the stub notice and the saved filter that matched nothing.
    @ViewBuilder private var statusLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            if picker.autoState == .exhausted {
                note(T("Nothing started on its own. Pick a source."), tone: BP.inkMuted)
            }
            if model.p2pStarting {
                HStack(spacing: 8) {
                    ProgressView().tint(BP.accent).accessibilityHidden(true)
                    Text(verbatim: T("Looking for peers…")).font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline)).foregroundStyle(BP.ink)
                }
            }
            switch model.phase {
            case .searching, .done:
                Text(verbatim: picker.sourcesLine)
                    .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("picker-sources")
            case .failed(let why):
                note(why, tone: BP.danger)
            case .idle:
                EmptyView()
            }
            if let resolveError = picker.resolveError { note(resolveError, tone: BP.danger) }
            if picker.stubNotice {
                note(T("Last source wasn't actually cached on your debrid yet. Pick another from the list."), tone: BP.inkMuted)
            }
            if picker.filterPool.fellBack, model.activeFilterId != nil {
                note(T("No sources match your filter. Showing all sources."), tone: BP.inkMuted)
            }
            if let notice = external.notice {
                note(notice, tone: BP.inkMuted).accessibilityIdentifier("picker-external-note")
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    private func note(_ text: String, tone: Color) -> some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(tone.opacity(0.12)))
    }

    /// One addon's run of rows (the default addon sort lists them grouped, in installed order).
    private struct AddonSection: Identifiable {
        let id: String
        let name: String
        let streams: [ScoredStream]
    }

    /// A row's stream with the picker state it draws: the lazy stack re-draws a row when its element
    /// changes, and a stream alone does not change when its resolve fails (the "Unavailable" mark).
    private struct RowItem: Identifiable, Equatable {
        let stream: ScoredStream
        let failed: Bool
        let resolving: Bool
        var id: ScoredStream.ID { stream.id }
    }

    /// Consecutive rows from the same addon, under its name. In Harbor's ranking one flat section,
    /// each row still naming its addon.
    private var sections: [AddonSection] {
        let rows: [ScoredStream] = picker.showOnline ? picker.visible : []
        guard picker.sortByAddon else { return rows.isEmpty ? [] : [AddonSection(id: "ranked", name: "", streams: rows)] }
        var out: [AddonSection] = []
        for s in rows {
            if let last = out.last, last.name == s.addonName {
                out[out.count - 1] = AddonSection(id: last.id, name: last.name, streams: last.streams + [s])
            } else {
                out.append(AddonSection(id: "\(out.count)-\(s.addonName)", name: s.addonName, streams: [s]))
            }
        }
        return out
    }

    @ViewBuilder private var rows: some View {
        let groups: [AddonSection] = sections
        if picker.showHomeServers, !model.copies.isEmpty {
            sectionTitle(T("On your home servers"), count: model.copies.count)
            ForEach(model.copies) { c in copyRow(c) }
        }
        ForEach(groups) { g in
            if !g.name.isEmpty {
                sectionTitle(g.name, count: g.streams.count).padding(.top, 6)
            } else if picker.showHomeServers, !model.copies.isEmpty {
                sectionTitle(T("Addons"), count: g.streams.count).padding(.top, 6)
            }
            ForEach(g.streams.map { RowItem(stream: $0, failed: picker.failedIds.contains($0.id), resolving: picker.resolving == $0.id) }) { r in
                row(r.stream)
            }
        }
        if groups.isEmpty, !picker.showHomeServers || model.copies.isEmpty { emptyList }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(PhoneTheme.sans(13, .bold, relativeTo: .footnote)).textCase(.uppercase).tracking(0.8)
                .foregroundStyle(BP.inkMuted)
            Text(verbatim: "\(count)")
                .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption)).foregroundStyle(BP.inkSubtle)
        }
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("section-\(title)")
    }

    /// bp-streams empty state: skeleton rows while the search runs, else "No sources found" with the
    /// loosen ladder, or "No sources match these filters" with Clear filters.
    @ViewBuilder private var emptyList: some View {
        if picker.listLoading {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in SkeletonBlock(height: 92, radius: PhoneTheme.radiusMedium) }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: T("Looking for sources")))
            .accessibilityIdentifier("picker-loading")
        } else if picker.pool.isEmpty {
            VStack(spacing: 12) {
                EmptyState(title: T("No sources found"), systemImage: "shippingbox")
                if model.canLoosen {
                    HStack(spacing: 10) {
                        if model.strict {
                            Button(T("Search wider")) { PhoneFeedback.shared.tap(); Task { await model.searchWider() } }
                                .buttonStyle(.glassProminent)
                                .accessibilityIdentifier("picker-search-wider")
                        }
                        if !model.showAll {
                            Button(T("Show everything")) { PhoneFeedback.shared.tap(); Task { await model.showEverything() } }
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("picker-show-everything")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        } else {
            EmptyState(title: T("No sources match these filters"), systemImage: "line.3.horizontal.decrease.circle",
                       actionTitle: T("Clear filters")) {
                PhoneFeedback.shared.selection()
                withMotion(.snappy) { picker.clearFilters() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
    }

    // MARK: rows

    private func row(_ s: ScoredStream) -> some View {
        let failed: Bool = picker.failedIds.contains(s.id)
        let highlight: Bool = picker.isHighlighted(s)
        let headline: String = s.tvRow?.headline ?? s.parsedTitle ?? s.title ?? s.name ?? "Stream"
        return Button {
            press(s, .setting)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        if let labels = s.tvLabels {
                            rowMeta(s, labels)
                        } else {
                            PhoneFlowRow {
                                ForEach(Self.badges(s), id: \.self) { b in PhoneTextBadge(text: b == "Cached" ? T("Cached") : b) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if model.rememberedIndex == s.index {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(BP.ink)
                            .accessibilityHidden(true)
                    }
                    if picker.resolving == s.id {
                        ProgressView().controlSize(.small).tint(BP.inkMuted).accessibilityHidden(true)
                    } else if let labels = s.tvLabels {
                        availabilityMark(labels)
                    }
                }
                Text(verbatim: Self.firstLine(headline))
                    .font(PhoneTheme.sans(15, .semibold, relativeTo: .body))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                if let text = s.tvRow, SettingsBridge.shared.slice.fullStreamDescription ?? true, !text.description.isEmpty {
                    Text(verbatim: Self.tidy(text.description))
                        .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                        .lines(6)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let text = s.tvRow, !text.detail.isEmpty {
                    Text(verbatim: text.detail)
                        .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                        .lines(2)
                } else {
                    let bits: [String] = Self.summary(s)
                    if !bits.isEmpty {
                        Text(verbatim: bits.joined(separator: " · "))
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote)).foregroundStyle(BP.inkSubtle)
                    }
                }
                if SettingsBridge.shared.slice.pickerShowFilename ?? false, let name = s.tvRow?.filename, !name.isEmpty, name != headline {
                    Text(verbatim: name)
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(BP.inkSubtle)
                        .lines(1).truncationMode(.middle)
                }
                if failed {
                    Label { Text(verbatim: T("Unavailable, try another.")) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(PhoneTheme.sans(13, .bold, relativeTo: .footnote)).foregroundStyle(BP.danger)
                        .accessibilityIdentifier("stream-failed-\(s.index)")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(highlight ? BP.panel2 : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous)
                .stroke(highlight ? BP.accent.opacity(0.6) : BP.edge, lineWidth: 1))
            .opacity(failed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .contextMenu { if switching == nil { playMenu(s) } }
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: rowLabel(s, headline: headline, failed: failed)))
        .accessibilityHint(Text(verbatim: T("Plays this source")))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("stream-\(s.index)")
    }

    /// A row's pick, aimed at Harbor's player, an external one, or wherever the Player setting says.
    /// A press while another row resolves does nothing (rowPressed), so nothing is aimed then.
    private func press(_ s: ScoredStream, _ target: PhoneExternalPlay.Target) {
        guard picker.resolving == nil else { return }
        // In the player the pick swaps the stream; there is nothing to aim elsewhere.
        if switching == nil { external.aim(target, at: s.id) }
        picker.rowPressed(s)
    }

    /// The row's touch-and-hold menu: "Open in…" the installed players, and Harbor's own
    /// player when the Player setting sends picks elsewhere.
    @ViewBuilder private func playMenu(_ s: ScoredStream) -> some View {
        if external.preferred != nil {
            Button { press(s, .builtIn) } label: { Label(T("Play in Harbor"), systemImage: "play.fill") }
                .accessibilityIdentifier("play-in-harbor")
        }
        Menu {
            if !ExternalReach.rowMayReach(availability: s.tvLabels?.availability, url: s.url) {
                Button {} label: { Text(verbatim: ExternalReach.local.reason ?? "") }
                    .disabled(true)
                    .accessibilityIdentifier("open-in-unavailable")
            } else if external.installed.isEmpty {
                Button {} label: { Text(verbatim: T("No other video players installed")) }
                    .disabled(true)
                    .accessibilityIdentifier("open-in-none")
            } else {
                ForEach(external.installed) { p in
                    Button { press(s, .player(p)) } label: { Text(verbatim: p.name) }
                        .accessibilityIdentifier("open-in-\(p.id)")
                }
            }
        } label: {
            Label(T("Open in…"), systemImage: "arrow.up.forward.app")
        }
        .accessibilityIdentifier("open-in")
    }

    /// What VoiceOver reads for a row: quality, addon, availability, languages, the title, and why it
    /// is dimmed.
    private func rowLabel(_ s: ScoredStream, headline: String, failed: Bool) -> String {
        var parts: [String] = []
        if let labels = s.tvLabels {
            parts.append(labels.confidence == "labeled" ? labels.quality : T(labels.quality))
            parts.append(s.addonName)
            parts.append(availabilityText(labels))
            let formats: [String] = (labels.formats ?? []).map(\.text)
            if !formats.isEmpty { parts.append(formats.joined(separator: ", ")) }
        } else {
            parts.append(s.addonName)
            parts.append(contentsOf: Self.badges(s))
        }
        let langs: [String] = PhoneFlagStack.streamLanguages(s.audioLanguages)
        if !langs.isEmpty { parts.append(langs.joined(separator: ", ")) }
        parts.append(Self.firstLine(headline))
        if model.rememberedIndex == s.index { parts.append(T("Played last")) }
        if failed { parts.append(T("Unavailable, try another.")) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// bp-stream-row.tsx META: the quality pill, the addon (in the ranked list; a section names it
    /// otherwise), the DUB/SUB pill, the format badges, the edition and the language flags.
    private func rowMeta(_ s: ScoredStream, _ labels: ScoredStream.Labels) -> some View {
        let slice = SettingsBridge.shared.slice
        let showQuality: Bool = slice.showQualityBadge ?? true
        let showDub: Bool = slice.showDubBadge ?? true
        return PhoneFlowRow {
            if showQuality { PhoneQualityPill(labels: labels) }
            if !picker.sortByAddon {
                Text(verbatim: s.addonName)
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2)).textCase(.uppercase).tracking(1)
                    .foregroundStyle(BP.inkMuted).lines(1)
            }
            if showDub, let kind = labels.dubSub { PhoneDubSubPill(kind: kind) }
            if showQuality, let formats = labels.formats {
                ForEach(formats, id: \.kind) { PhoneFormatBadge(format: $0) }
            } else if showQuality {
                ForEach(labels.badges, id: \.self) { PhoneTextBadge(text: $0) }
            }
            if let edition = labels.edition {
                Text(verbatim: edition)
                    .font(PhoneTheme.sans(10, .bold, relativeTo: .caption2)).textCase(.uppercase).tracking(1)
                    .foregroundStyle(BP.inkMuted).lines(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(BP.glass))
            }
            let flagLangs: [String] = PhoneFlagStack.streamLanguages(s.audioLanguages)
            if !flagLangs.isEmpty { PhoneFlagStack(languages: flagLangs, maxCount: 4) }
        }
    }

    /// bp-stream-row.tsx right-hand mark: "In {name}", "Cached on {name}", "Cached"; else External,
    /// P2P, or Cache (a source the debrid would have to fetch first).
    @ViewBuilder private func availabilityMark(_ labels: ScoredStream.Labels) -> some View {
        let kind: String = labels.availability ?? ""
        if let icon = Self.availabilityIcon[kind] {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(kind == "cached" ? BP.live : BP.inkMuted)
                Text(verbatim: availabilityText(labels))
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2)).foregroundStyle(BP.ink).lines(1)
            }
            .fixedSize()
            .accessibilityHidden(true)
        }
    }

    private static let availabilityIcon: [String: String] = [
        "cached": "checkmark", "external": "arrow.up.right.square",
        "p2p": "point.3.connected.trianglepath.dotted", "cache": "arrow.down.to.line",
    ]

    private func availabilityText(_ labels: ScoredStream.Labels) -> String {
        switch labels.availability ?? "" {
        case "cached":
            if let on = labels.cachedOn { return on.owned ? T("In %@", on.name) : T("Cached on %@", on.name) }
            return T("Cached")
        case "external": return T("External")
        case "p2p": return T("P2P")
        case "cache": return T("Cache")
        default: return ""
        }
    }

    /// bp-streams home-server copy row: resolution and quality, Resume, the server and the version.
    private func copyRow(_ c: StreamsModel.HomeCopy) -> some View {
        Button {
            picker.copyPressed(c)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    PhoneFlowRow {
                        if let r = c.resolution { PhoneTextBadge(text: r) }
                        if let q = c.quality, q != c.resolution { PhoneTextBadge(text: q) }
                        if c.progressMs > 0 { PhoneTextBadge(text: T("Resume")) }
                        Text(verbatim: c.sourceLabel)
                            .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2)).textCase(.uppercase).tracking(1)
                            .foregroundStyle(BP.inkMuted).lines(1)
                    }
                    Text(verbatim: c.label).font(PhoneTheme.sans(15, .semibold, relativeTo: .body)).foregroundStyle(BP.ink).lines(2)
                    if let bytes = c.sizeBytes, bytes > 0 {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkSubtle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if picker.resolving == c.key { ProgressView().controlSize(.small).tint(BP.inkMuted).accessibilityHidden(true) }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copy-\(c.key)")
    }

    /// The one-line summary for a stream with no row text: release group, size, seeders, languages.
    static func summary(_ s: ScoredStream) -> [String] {
        var out: [String] = []
        if let g = s.releaseGroup, !g.isEmpty { out.append(g) }
        if let sz = s.sizeText { out.append(sz) }
        if let seeds = s.seeders, seeds > 0 { out.append(T("%lld seeders", Int(seeds))) }
        if let langs = s.audioLanguages, !langs.isEmpty { out.append(langs.prefix(3).joined(separator: ", ")) }
        return out
    }

    /// The P2P dialog's line: seeders, size and the badge words.
    static func p2pSummary(_ s: ScoredStream) -> [String] {
        var out: [String] = []
        if let seeds = s.seeders { out.append(T("%lld seeders", Int(seeds))) }
        if let sz = s.sizeText { out.append(sz) }
        out.append(contentsOf: badges(s).filter { $0 != "Cached" })
        return out
    }

    /// The badge words for a stream the engine sent without labels (the TV's `badges(_:)`).
    static func badges(_ s: ScoredStream) -> [String] {
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

    static func firstLine(_ text: String) -> String {
        let line: Substring = text.split(whereSeparator: { $0.isNewline }).first ?? Substring(text)
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Lines of separators alone go, and a trailing separator is trimmed.
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

    // MARK: dialogs (bp-stream-dialogs.tsx)

    @ViewBuilder private func dialogView(_ d: PickerDialog) -> some View {
        switch d {
        case .p2p(let s):
            PhonePickerDialog(icon: "point.3.connected.trianglepath.dotted", title: T("Stream this via peer-to-peer?"),
                              message: T("This source isn't cached on your debrid, so Harbor would pull it directly from peers. It can take a moment to start and may buffer on low-seed torrents.")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: s.parsedTitle ?? s.title ?? s.name ?? T("This source"))
                        .font(.system(.footnote, design: .monospaced)).foregroundStyle(BP.ink).lines(3)
                    let bits: [String] = Self.p2pSummary(s)
                    if !bits.isEmpty {
                        Text(verbatim: bits.joined(separator: " · "))
                            .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkSubtle)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.panel2))
                .accessibilityElement(children: .combine)
            } buttons: {
                dialogButton(T("Stream"), id: "p2p-stream", primary: true) { picker.streamViaP2p(s, always: false) }
                dialogButton(T("Always stream P2P"), id: "p2p-always") { picker.streamViaP2p(s, always: true) }
                dialogButton(T("Cancel"), id: "p2p-cancel") { picker.dialog = nil }
            }
        case .debridDown:
            PhonePickerDialog(icon: "exclamationmark.icloud", title: T("Your debrid service can't process this right now."),
                              message: T("Real-Debrid, TorBox, AllDebrid and Premiumize all have brief outages where they stop returning links. Wait a few minutes and try again, or check the service's status page.")) {
                EmptyView()
            } buttons: {
                dialogButton(T("Try again"), id: "debrid-retry", primary: true) { picker.resetDebridDown() }
                dialogButton(T("Back"), id: "dialog-back") { picker.closePicker() }
            }
        case .noSources:
            PhonePickerDialog(icon: "shippingbox", title: T("No streaming sources yet"),
                              message: T("Harbor needs at least one streaming source before it can play %@. Install a stream addon or add a debrid key in settings.", meta.name)) {
                EmptyView()
            } buttons: {
                dialogButton(T("Back"), id: "dialog-back", primary: true) { picker.closePicker() }
            }
        case .exhausted(let n):
            PhonePickerDialog(icon: "exclamationmark.triangle", title: T("We could not find a working stream"),
                              message: T("Harbor tried %lld sources for %@ and none of them played. Usually that means a debrid key has expired, no stream addon is installed yet, or nothing has this title cached.", n, picker.exhaustedLabel)) {
                EmptyView()
            } buttons: {
                dialogButton(T("Browse sources"), id: "dialog-browse", primary: true) { picker.browseManually() }
                dialogButton(T("Back"), id: "dialog-back") { picker.closePicker() }
            }
        }
    }

    @ViewBuilder private func dialogButton(_ title: String, id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        let button = Button {
            PhoneFeedback.shared.tap()
            action()
        } label: {
            Text(verbatim: title).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityIdentifier(id)
        if primary { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }
}

/// One of the picker's dialogs as a small sheet: an icon, the title, the message, what the dialog
/// shows of the stream, and its buttons stacked full width.
private struct PhonePickerDialog<Extra: View, Buttons: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let extra: () -> Extra
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(BP.accent)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(PhoneTheme.display(22, .semibold, relativeTo: .title2)).foregroundStyle(BP.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: message)
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .callout)).foregroundStyle(BP.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
                VStack(spacing: 10) { buttons() }.padding(.top, 4)
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("picker-dialog")
    }
}

/// bp-stream-row.tsx quality pill: the label (translated when it is "No Label" / "Unverified").
struct PhoneQualityPill: View {
    let labels: ScoredStream.Labels

    var body: some View {
        // "No Label" and "Unverified" are catalog keys; QUALITY_LABEL values are not translated upstream.
        let quality: String = labels.confidence == "labeled" ? labels.quality : T(labels.quality)
        Text(verbatim: quality)
            .font(PhoneTheme.sans(12, .heavy, relativeTo: .caption)).foregroundStyle(BP.ink).lines(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BP.glass))
    }
}

/// components/dub-sub-pill.tsx: SUB quiet, DUB in the accent, DUAL in emerald.
struct PhoneDubSubPill: View {
    let kind: String

    var body: some View {
        let text: String = kind == "dual" ? "DUAL" : (kind == "dub" ? "DUB" : "SUB")
        let emerald300 = Color(red: 0.431, green: 0.906, blue: 0.718)
        let emerald400 = Color(red: 0.204, green: 0.827, blue: 0.600)
        let emerald500 = Color(red: 0.063, green: 0.725, blue: 0.506)
        let fg: Color = kind == "dual" ? emerald300 : (kind == "dub" ? BP.accent : BP.inkSubtle)
        let bg: Color = kind == "dual" ? emerald500.opacity(0.15) : (kind == "dub" ? BP.accent.opacity(0.15) : BP.canvas.opacity(0.7))
        let ring: Color = kind == "dual" ? emerald400.opacity(0.3) : (kind == "dub" ? BP.accent.opacity(0.35) : BP.edge)
        Text(verbatim: text)
            .font(PhoneTheme.sans(10, .bold, relativeTo: .caption2)).tracking(0.8).foregroundStyle(fg).lines(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ring, lineWidth: 1))
    }
}
