import SwiftUI

/// `S{imdbSeason ?? season} · E{02}{ · name}`, as both steps print an episode.
private func episodeLine(_ episode: AnyJSON?) -> String? {
    guard let s = episode?["imdbSeason"]?.number ?? episode?["season"]?.number,
          let e = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number,
          s.isFinite, e.isFinite else { return nil }
    var line = "S\(clampedInt(s)) · E" + String(format: "%02d", clampedInt(e))
    if let name = episode?["name"]?.string, !name.isEmpty { line += " · " + name }
    return line
}

/// The picker's auto step on the phone (bp-stream-steps.tsx BpAutoStep; a kid profile gets
/// auto-play-transition.tsx's captions): the title over its blurred art, which source is being
/// tried, and "Choose a source instead". It stands in for the list while instant play is busy.
struct PhonePickerAutoStep: View {
    let meta: Meta
    let episode: AnyJSON?
    /// The candidate being tried (0 = the first).
    let attemptIdx: Int
    /// A candidate is being resolved right now.
    let resolving: Bool
    /// That candidate is being fetched over P2P.
    let p2p: Bool
    let kid: Bool
    /// The player just sent a stub back; the picker clears it after 6 s.
    var stubNotice = false
    let onCancel: () -> Void

    /// auto-play-transition.tsx p2pStage: 1 after 6 s, 2 after 25 s of a P2P resolve (kid branch).
    @State private var p2pStage = 0

    private var backdrop: String? {
        [episode?["still"]?.string, meta.background, meta.poster].compactMap { $0 }.first { !$0.isEmpty }
    }

    private var caption: String {
        if kid, p2pStage == 2 { return "P2P · " + T("Stream is taking a while") }
        if kid, p2pStage == 1 { return "P2P · " + T("Searching sources…") }
        return attemptIdx > 0 ? T("Trying source %lld", attemptIdx + 1) : T("Connecting")
    }

    var body: some View {
        ZStack {
            if let backdrop {
                PhoneImage(url: backdrop, plate: false, decodeScale: 0.25)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 28, opaque: true)
                    .opacity(0.25)
                    .accessibilityHidden(true)
            }
            BP.void_.opacity(0.72)
            ScrollView {
                VStack(spacing: 18) {
                    if let logo = meta.logo, !logo.isEmpty {
                        PhoneImage(url: logo, contentMode: .fit, plate: false)
                            .frame(maxWidth: 260, maxHeight: 80)
                            .shadow(color: .black.opacity(0.75), radius: 14, y: 6)
                            .accessibilityLabel(Text(verbatim: meta.name))
                    } else {
                        Text(verbatim: meta.name)
                            .font(PhoneTheme.display(28, .semibold, relativeTo: .title))
                            .foregroundStyle(BP.ink)
                            .multilineTextAlignment(.center).lines(3)
                    }
                    if let line = episodeLine(episode) {
                        Text(verbatim: line)
                            .font(PhoneTheme.sans(12, .bold, relativeTo: .caption)).textCase(.uppercase).tracking(2)
                            .foregroundStyle(BP.inkSubtle).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 9) {
                        ProgressView().tint(BP.inkSubtle).accessibilityHidden(true)
                        Text(verbatim: caption)
                            .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline)).foregroundStyle(BP.inkSubtle)
                    }
                    .accessibilityElement(children: .combine)
                    // The step's handle for UI tests: an id on the step's own container is lost, since the
                    // container fills the picker's "phone-picker" container and SwiftUI folds the two together.
                    .accessibilityIdentifier("auto-caption")
                    if kid, p2pStage == 2 {
                        Text(verbatim: T("This source is slow. Try another."))
                            .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    if stubNotice {
                        Text(verbatim: T("Last source wasn't actually cached on your debrid yet. Trying another."))
                            .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                            .foregroundStyle(Color(red: 0.992, green: 0.902, blue: 0.541).opacity(0.8))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        PhoneFeedback.shared.tap()
                        onCancel()
                    } label: {
                        Label { Text(verbatim: T("Choose a source instead")) } icon: { Image(systemName: "xmark") }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .padding(.top, 6)
                    .accessibilityIdentifier("auto-cancel")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // The P2P stages restart with each attempt and only run while a P2P source resolves.
        .task(id: "\(attemptIdx)|\(p2p)|\(resolving)") {
            p2pStage = 0
            guard kid, resolving, p2p else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            p2pStage = 1
            try? await Task.sleep(for: .seconds(19))
            guard !Task.isCancelled else { return }
            p2pStage = 2
        }
    }
}

/// bp-subtitle-step.tsx on the phone: "Choose subtitles" between a pick by hand and the player
/// (settings.subtitlePreselect). The engine's `subtitles.choices` lists the tracks, best match
/// selected; language chips narrow them; "Start playback" hands the selection over, "Skip, let
/// Harbor choose" hands nothing over, Back returns to the list.
struct PhoneSubtitleStep: View {
    let meta: Meta
    let episode: AnyJSON?
    let imdbId: String?
    let imdbVerified: Bool
    let streamRef: AnyJSON?
    let filename: String?
    let onStart: (SubtitlePreselect?) -> Void
    let onCancel: () -> Void

    struct Choice: Decodable, Identifiable, Equatable {
        var id: String
        var url: String
        var lang: String
        var langKey: String
        var label: String
        var detail: String
        var flag: String?
    }
    struct LangGroup: Decodable, Equatable {
        var langKey: String
        var langDisplay: String
        var count: Int
    }
    struct Choices: Decodable {
        var error: Bool
        var results: [Choice]
        var groups: [LangGroup]
        var bestId: String?
    }
    /// engine SubtitleStepSrc.
    private struct Src: Encodable {
        var meta: Meta
        var episode: AnyJSON?
        var imdbId: String?
        var imdbIdVerified: Bool
        var streamRef: AnyJSON?
        var filename: String?
    }

    @State private var loading = true
    @State private var failed = false
    @State private var results: [Choice] = []
    @State private var groups: [LangGroup] = []
    @State private var bestId: String?
    @State private var selected: String?
    @State private var activeLang = "all"

    private static let offId = "off"

    private var context: String {
        guard let s = episode?["imdbSeason"]?.number ?? episode?["season"]?.number,
              let e = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number,
              s.isFinite, e.isFinite else { return meta.name }
        return meta.name + " · S" + String(clampedInt(s)) + "E" + String(clampedInt(e))
    }

    private var visible: [Choice] {
        activeLang == "all" ? results : results.filter { $0.langKey == activeLang }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    ChipRow {
                        GlassChip(title: T("All languages") + " " + String(results.count), selected: activeLang == "all") {
                            PhoneFeedback.shared.selection()
                            activeLang = "all"
                        }
                        ForEach(groups, id: \.langKey) { g in
                            GlassChip(title: g.langDisplay + " " + String(g.count), selected: activeLang == g.langKey) {
                                PhoneFeedback.shared.selection()
                                activeLang = g.langKey
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        trackRow(id: Self.offId, label: T("No subtitles"), detail: nil, best: false, flag: nil, offRow: true)
                        if loading {
                            HStack(spacing: 10) {
                                ProgressView().tint(BP.inkSubtle).accessibilityHidden(true)
                                Text(verbatim: T("Finding subtitles…"))
                            }
                            .font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline)).foregroundStyle(BP.inkSubtle)
                            .padding(.vertical, 6)
                        } else if results.isEmpty {
                            Text(verbatim: failed
                                 ? T("Couldn't load subtitles. You can start anyway and add one later in the player.")
                                 : T("No subtitles found. Start anyway, Harbor keeps looking while you watch."))
                                .font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline)).foregroundStyle(BP.inkSubtle)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("subtitle-empty")
                        }
                        ForEach(visible) { r in
                            trackRow(id: r.id, label: r.label, detail: r.detail, best: r.id == bestId, flag: r.flag, offRow: false)
                        }
                    }
                    .padding(.horizontal, PhoneTheme.margin)
                }
                .padding(.top, 18)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            actions
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(verbatim: T("Choose subtitles")) } icon: { Image(systemName: "captions.bubble") }
                .font(PhoneTheme.display(24, .semibold, relativeTo: .title2)).foregroundStyle(BP.ink)
                .accessibilityAddTraits(.isHeader)
                // The step's handle for UI tests (see auto-caption above).
                .accessibilityIdentifier("subtitle-title")
            Text(verbatim: context + " · " + (loading ? T("Finding subtitles…") : T("%lld tracks", results.count)))
                .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline)).foregroundStyle(BP.inkSubtle)
                .lines(2)
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    /// BpTrackRow: a check when selected (else the flag, or "captions off"), the label with the
    /// "Best match" pill, and the detail line.
    private func trackRow(id: String, label: String, detail: String?, best: Bool, flag: String?, offRow: Bool) -> some View {
        let isOn: Bool = selected == id
        return Button {
            PhoneFeedback.shared.selection()
            selected = id
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(BP.panel2)
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy))
                    } else if offRow {
                        Image(systemName: "captions.bubble.fill").font(.system(size: 14, weight: .semibold)).opacity(0.45)
                    } else if let flag, !flag.isEmpty {
                        Text(verbatim: flag).font(.system(size: 18))
                    } else {
                        Image(systemName: "captions.bubble").font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(width: 38, height: 38)
                .foregroundStyle(BP.ink)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: label).font(PhoneTheme.sans(16, .semibold, relativeTo: .body)).foregroundStyle(BP.ink).lines(2)
                        if best {
                            Text(verbatim: T("Best match"))
                                .font(PhoneTheme.sans(10, .bold, relativeTo: .caption2)).textCase(.uppercase).tracking(1)
                                .foregroundStyle(BP.ink)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(BP.glass))
                                .fixedSize()
                        }
                    }
                    if let detail, !detail.isEmpty {
                        Text(verbatim: detail).font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkMuted).lines(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(isOn ? BP.glass : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).stroke(isOn ? BP.accent.opacity(0.6) : BP.edge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("track-\(id)")
    }

    /// Back, Skip and Start playback, stacked under the list so the thumb reaches them.
    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                PhoneFeedback.shared.tap()
                start()
            } label: {
                Label { Text(verbatim: T("Start playback")) } icon: { Image(systemName: "play.fill") }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("subtitle-start")
            HStack(spacing: 10) {
                Button {
                    PhoneFeedback.shared.tap()
                    onCancel()
                } label: {
                    Text(verbatim: T("Back")).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("subtitle-back")
                Button {
                    PhoneFeedback.shared.tap()
                    onStart(nil)
                } label: {
                    Text(verbatim: T("Skip, let Harbor choose")).frame(maxWidth: .infinity).lines(2).minimumScaleFactor(0.8)
                }
                .accessibilityIdentifier("subtitle-skip")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// bp-subtitle-step start(): "off", the selected result, or nothing.
    private func start() {
        if selected == Self.offId {
            onStart(SubtitlePreselect(off: true))
            return
        }
        if let id = selected, let r = results.first(where: { $0.id == id }) {
            onStart(SubtitlePreselect(off: false, url: r.url, lang: r.lang, title: r.label))
            return
        }
        onStart(nil)
    }

    // MARK: load (use-subtitle-choices)

    private func load() async {
        let out: Choices?
        if StreamsModel.usesFixtures {
            out = await Self.fixtureChoices()
        } else {
            let p = ProfilesStore.shared.active
            let authKey: String? = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
            let src = Src(meta: meta, episode: episode, imdbId: imdbId, imdbIdVerified: imdbVerified, streamRef: streamRef, filename: filename)
            let args: [any Encodable] = [p?.id ?? "default", p?.linked ?? true, authKey, src]
            out = try? await HarborEngine.shared.call("subtitles.choices", args)
        }
        guard !Task.isCancelled else { return }
        var seen: Set<String> = []
        let unique: [Choice] = (out?.results ?? []).filter { seen.insert($0.id).inserted }
        results = unique
        groups = out?.groups ?? []
        bestId = out?.bestId
        failed = out?.error ?? true
        loading = false
        if let best = bestId, let r = unique.first(where: { $0.id == best }) {
            selected = best
            activeLang = r.langKey
        } else {
            selected = Self.offId
        }
    }

    /// `--fixture-streams`: three tracks, English the best match, after a short beat.
    private static func fixtureChoices() async -> Choices {
        try? await Task.sleep(for: .milliseconds(400))
        let results: [Choice] = [
            Choice(id: "fx-sub-en", url: "https://fixtures.harbor.invalid/subs/en.srt", lang: "eng", langKey: "en",
                   label: "English", detail: "OpenSubtitles · Dune.Part.Two.2024.2160p", flag: "🇬🇧"),
            Choice(id: "fx-sub-es", url: "https://fixtures.harbor.invalid/subs/es.srt", lang: "spa", langKey: "es",
                   label: "Español", detail: "OpenSubtitles · Dune.Part.Two.2024.1080p", flag: "🇪🇸"),
            Choice(id: "fx-sub-fr", url: "https://fixtures.harbor.invalid/subs/fr.srt", lang: "fre", langKey: "fr",
                   label: "Français", detail: "Addon · Dune.Part.Two.2024.WEB-DL", flag: "🇫🇷"),
        ]
        let groups: [LangGroup] = [
            LangGroup(langKey: "en", langDisplay: "English", count: 1),
            LangGroup(langKey: "es", langDisplay: "Español", count: 1),
            LangGroup(langKey: "fr", langDisplay: "Français", count: 1),
        ]
        return Choices(error: false, results: results, groups: groups, bestId: "fx-sub-en")
    }
}
