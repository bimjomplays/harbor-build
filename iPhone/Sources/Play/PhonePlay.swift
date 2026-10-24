import SwiftUI

/// A stream the play picker settled on: the title, the episode, the row picked (nil for a home-server
/// copy) and the resolved link with the picker's extras (the subtitle step's choice, the stream ref).
struct PhonePlayStream: Identifiable {
    let id = UUID()
    let meta: Meta
    let episode: AnyJSON?
    let stream: ScoredStream?
    let resolved: StreamsModel.Resolved
}

/// What the player cover plays: the TV's DetailView.PlayTarget, built from the picker's pick
///, with the request it came from (where a close goes next).
struct PhonePlayerTarget: Identifiable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let title: String
    /// "S1 E2 · name" for an episode.
    let subtitle: String?
    let context: PlaybackContext
    /// The up-next card's line (views/player.tsx nextEpMask), nil without an aired next episode.
    let upNext: String?
    let episode: AnyJSON?
    /// What the Auto engine rule reads (engine/player.ts pickEngine).
    let hints: PlayerStreamHints
    /// PlayerSrc autoFired / attempt / streamRef (views/player.tsx next-stream skip).
    let pick: PlayerPickInfo
    /// PlayerSrc.subtitles: the stream's own subtitles.
    let subtitles: [SeedSubtitle]
    /// PlayerSrc.subtitlePreselect: the picker's subtitle step chose it.
    let preselect: SubtitlePreselect?
    let request: PhonePlay.Request
}

/// The one way a phone screen starts playback (a title page's Play / Resume, an episode row, Sources,
/// a Continue Watching resume) and where the play picker's pick goes.
/// `request(meta:video:auto:detail:)` opens PhonePlayPicker over the screen that asked; a pick comes
/// back through `handOff(stream:)`, which closes the picker and opens the player cover
/// (PhonePlayerView) once the picker's sheet has gone. A close that goes on somewhere (the next
/// episode, another source, Try another) opens the picker again once the cover has gone, as the
/// TV's DetailView does.
@MainActor
final class PhonePlay: ObservableObject {
    static let shared = PhonePlay()

    struct Request: Identifiable {
        let id = UUID()
        let meta: Meta
        /// The episode to play (DetailModel.Episode.playEpisode, or the premiere); nil for a film.
        let video: AnyJSON?
        /// Asked from a sheet with its own play host (the deep-link title sheet, the account sheet's
        /// Addons pages): the sheet presents it, the shell under it cannot.
        let inCover: Bool
        /// bp-detail's instantPlay: the picker's auto step tries the best sources first.
        let autoPlay: Bool
        /// bp-detail's play(): the playback-source preference (home server or online) applies.
        let applyPreference: Bool
        /// The title page that asked: the next / previous episode and the up-next line come from it.
        var detail: DetailModel? = nil
        /// PlayerSrc.attempt: how many times the player has sent this title back to the picker.
        var attempt: Int = 0
        /// Switch source: the new stream starts where the old one was (use-bridge-load hasExplicitStart).
        var switchFromSec: Double? = nil

        /// The same title and host, opened again for `video`.
        func again(video: AnyJSON?, autoPlay: Bool, attempt: Int = 0, switchFromSec: Double? = nil) -> Request {
            Request(meta: meta, video: video, inCover: inCover, autoPlay: autoPlay, applyPreference: false,
                    detail: detail, attempt: attempt, switchFromSec: switchFromSec)
        }
    }

    @Published var pending: Request?
    /// The player: a root overlay (PhonePlayerOverlay) for a pick from the shell, so it can step aside
    /// while the picture floats; a cover over the deep-link title sheet for a pick from that sheet.
    @Published var playing: PhonePlayerTarget?
    /// Counts the times the floating picture asked for the player back (its window's restore button):
    /// whatever the shell has open over the player's overlay closes on it.
    @Published private(set) var returns = 0
    /// A pick waiting for its picker's sheet to go: a cover presented over a dismissing sheet is dropped.
    private var queued: PhonePlayerTarget?
    /// Where a close goes next (another picker), run once the player's cover has gone.
    private var afterClose: (() -> Void)?
    /// Continue Watching's one-press resume: the title sheet for this id plays at once (PhoneDetailSheet).
    private var autoPlayTitle: (id: String, hint: PhoneEpisodeHint?)?

    /// Play `meta` (and `video`, an episode payload as the TV's picker takes it). `auto` is a Play /
    /// Resume or episode press, which plays the best source when instant play is on and follows the
    /// source preference, as the TV's; Sources passes false and only lists them.
    static func request(meta: Meta, video: AnyJSON?, auto: Bool = true, detail: DetailModel? = nil) {
        PhoneFeedback.shared.tap()
        let covers = PhonePresence.shared.covers
        let inCover = covers.contains(PhoneDetailSheet.presenceId) || covers.contains(PhoneAccountSheet.presenceId)
        let instant: Bool = SettingsBridge.shared.slice.instantPlay ?? true
        shared.pending = Request(meta: meta, video: video, inCover: inCover,
                                 autoPlay: auto && instant, applyPreference: auto, detail: detail)
    }

    /// The picker's pick: the target is built while the picker is still up (the up-next line is an
    /// engine read), then the picker goes and the player follows it.
    static func handOff(stream: PhonePlayStream) {
        // An external player: "Open in…" or the Player setting.
        if PhoneExternalPlay.shared.take(stream) { return }
        guard let request = shared.pending, let link = stream.resolved.data, let url = PlayableURL.make(link.url) else { return }
        PhoneFeedback.shared.success()
        // Another video while a picture floats: the floating one stops and saves first (PiPBrowse's "end").
        PhoneMiniState.shared.end?()
        let ep: AnyJSON? = stream.episode
        let season: Int? = ep?["season"]?.number.map { Int($0) }
        let episode: Int? = ep?["episode"]?.number.map { Int($0) }
        let sub: String? = season.flatMap { s in
            episode.map { e in "S\(s) E\(e)" + (ep?["name"]?.string.map { " · \($0)" } ?? "") }
        }
        let meta: Meta = request.detail?.meta ?? stream.meta
        let ctx = PlaybackContext(meta: meta, season: season, episode: episode, videoId: ep?["videoId"]?.string,
                                  imdbId: meta.id.hasPrefix("tt") ? meta.id : nil, imdbVerified: meta.id.hasPrefix("tt"),
                                  homeServer: stream.resolved.homeServer, explicitStartSec: request.switchFromSec)
        let pick = PlayerPickInfo(autoPicked: stream.resolved.autoPicked ?? false, attempt: request.attempt, streamRef: stream.resolved.streamRef)
        let hints = PlayerStreamHints(notWebReady: link.notWebReady, container: stream.stream?.container,
                                      hdrFormat: stream.stream?.hdrFormat, filename: link.filename)
        Task { @MainActor in
            var upNext: String?
            // views/player.tsx nextEpMask: a hidden title leaves only "S E" on the up-next card.
            if let d = request.detail, let s = season, let e = episode, let n = d.airedNext(season: s, episode: e) {
                upNext = await d.upNextText(n)
            }
            // The viewer closed the picker meanwhile.
            guard shared.pending?.id == request.id else { return }
            shared.queued = PhonePlayerTarget(url: url, headers: link.headers ?? [:], title: meta.name, subtitle: sub, context: ctx,
                                              upNext: upNext, episode: ep, hints: hints, pick: pick, subtitles: link.subtitles ?? [],
                                              preselect: stream.resolved.subtitlePreselect, request: request)
            shared.pending = nil
        }
    }

    /// The picker's sheet has gone: the pick waiting on it plays.
    func pickerDismissed(inCover: Bool) {
        guard let q = queued, q.request.inCover == inCover else { return }
        queued = nil
        playing = q
    }

    /// The player's cover or overlay has gone: what its close asked for runs.
    func playerDismissed() {
        let next = afterClose
        afterClose = nil
        next?()
    }

    /// The overlay's player left the screen. One that is still `playing` went without a close (the
    /// shell under it was replaced): it is not started again by the next shell.
    func overlayGone(_ t: PhonePlayerTarget) {
        if playing?.id == t.id { playing = nil }
        playerDismissed()
    }

    /// The floating picture's window wants the player back: sheets over the shell give way to it.
    func pictureReturning() {
        returns += 1
    }

    /// The player closed (PlayerSession's onClose: `advancing`, the next episode is wanted).
    func closed(_ t: PhonePlayerTarget, advancing: Bool) {
        let detail = t.request.detail
        Task { await detail?.loadWatchedState() }
        // Auto-advance (player-spec §1.9, as the TV's): the next episode's picker, with instant play.
        if advancing, afterClose == nil, let detail, let s = t.context.season, let e = t.context.episode,
           let next = detail.airedNext(season: s, episode: e) {
            let instant: Bool = SettingsBridge.shared.slice.instantPlay ?? true
            afterClose = { [weak self] in self?.pending = t.request.again(video: next.playEpisode, autoPlay: instant) }
        }
        // Another video may have taken over while this one closed (a pick made over a floating picture).
        if playing?.id == t.id { playing = nil }
    }

    /// The player's own ways back to the picker (onChooseAnother, onSwitchSource, onPickAgain,
    /// onPreviousEpisode): each opens it once the cover has gone.
    func reopen(_ request: Request) {
        afterClose = { [weak self] in self?.pending = request }
    }

    /// bp-player-controls "Previous episode": the episode before this one, or nil (the first one, a
    /// special, a film, or no title page to read the list from).
    func previousEpisode(_ t: PhonePlayerTarget) -> (() -> Void)? {
        guard let detail = t.request.detail, let s = t.context.season, s > 0, let e = t.context.episode,
              let idx = detail.episodes.firstIndex(where: { $0.season == s && $0.episode == e }), idx > 0 else { return nil }
        let prev = detail.episodes[idx - 1]
        guard prev.season > 0 else { return nil }
        let instant: Bool = SettingsBridge.shared.slice.instantPlay ?? true
        let request = t.request.again(video: prev.playEpisode, autoPlay: instant)
        return { [weak self] in self?.reopen(request) }
    }

    /// Continue Watching's one-press resume (bp-cw-row bpCwResume): the title opens through the
    /// deep-link queue as before, and its sheet plays at once (the saved spot is where it starts).
    func resumeTitle(id: String, hint: PhoneEpisodeHint?) {
        autoPlayTitle = (id, hint)
    }

    /// The resume waiting for the title sheet of `id`, if any.
    func waitingResume(for id: String) -> (hint: PhoneEpisodeHint?, play: Bool) {
        guard let a = autoPlayTitle, a.id == id else { return (nil, false) }
        return (a.hint, true)
    }

    /// The title sheet for `id` is up: its resume is spent.
    func resumeShown(for id: String) {
        if autoPlayTitle?.id == id { autoPlayTitle = nil }
    }
}

extension View {
    /// Presents the play picker for the request made under this view, and (for the deep-link title
    /// sheet and the account sheet) the player its pick opens as a cover: the shell hosts the pickers
    /// from its tabs, and their player is PhonePlayerOverlay, at the root.
    func phonePlayHost(inCover: Bool) -> some View {
        modifier(PhonePlayHost(inCover: inCover))
    }
}

private struct PhonePlayHost: ViewModifier {
    let inCover: Bool
    @ObservedObject private var play = PhonePlay.shared

    private var request: Binding<PhonePlay.Request?> {
        Binding(
            get: { play.pending.flatMap { $0.inCover == inCover ? $0 : nil } },
            set: { if $0 == nil, play.pending?.inCover == inCover { play.pending = nil } }
        )
    }

    private var playing: Binding<PhonePlayerTarget?> {
        Binding(
            get: { play.playing.flatMap { inCover && $0.request.inCover ? $0 : nil } },
            set: { if $0 == nil, play.playing?.request.inCover == inCover { play.playing = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: request, onDismiss: { play.pickerDismissed(inCover: inCover) }) { request in
                PhonePlayPicker(meta: request.meta, video: request.video, dismiss: { play.pending = nil },
                                autoPlay: request.autoPlay, applyPreference: request.applyPreference)
            }
            // A player over the title sheet has to be a cover: the sheet would hide a root overlay.
            .fullScreenCover(item: playing, onDismiss: { play.playerDismissed() }) { target in
                PhonePlayerView(target: target, hoisted: false)
            }
    }
}

/// The player for a pick made from the shell: hosted at the root over everything (PhoneRootView),
/// not as a cover, so its session outlives the screen. While the picture floats in Picture in Picture
/// the overlay steps aside (PhonePlayerView `floating`) and the viewer browses Harbor, the tab bar's
/// accessory (PhoneMiniState) bringing the picture back.
struct PhonePlayerOverlay: View {
    @ObservedObject private var play = PhonePlay.shared

    var body: some View {
        ZStack {
            if let target = play.playing, !target.request.inCover {
                PhonePlayerView(target: target, hoisted: true)
                    .id(target.id)
                    .onDisappear { play.overlayGone(target) }
                    .transition(.opacity)
            }
        }
        .motion(.easeOut(duration: 0.25), value: play.playing?.id)
    }
}

/// `--fixtures detail --fixture-streams --phone-picker`: the play picker on a fixture film, over the
/// shell, with StreamsModel's fixture streams (App/Shared/Streams/StreamsFixtures.swift). The
/// subtitle-preselect setting is written for this launch (`--phone-picker-subtitles` on, else off),
/// so an earlier launch's value does not carry over.
enum PhonePickerFixture {
    static let meta = Meta(id: "fx-picker-movie", type: "movie", name: "Dune: Part Two", poster: nil, background: nil, logo: nil,
                           description: nil, releaseInfo: "2024", releaseDate: nil, inTheaters: nil, imdbRating: "8.5", tmdbScore: nil,
                           runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)

    /// The film to open the picker on, once the setting is written; nil without the flags.
    @MainActor static func open() async -> Meta? {
        guard Fixtures.active, PhoneLaunch.picker, StreamsModel.usesFixtures else { return nil }
        let on: Bool = PhoneLaunch.pickerSubtitles
        // The engine may still be booting: a few tries, then the picker opens with what the setting is.
        for _ in 0..<10 {
            if (try? await SettingsBridge.shared.patch(["subtitlePreselect": .bool(on)])) != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return meta
    }
}
