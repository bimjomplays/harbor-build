import SwiftUI

/// The playback session behind the player screen: everything
/// PlayerScreen used to hold as @State and do with the engines (resume, up next, skip segments,
/// retries, live reconnects, switching the source in place, progress saves, scrobbles, Picture in
/// Picture) with no view in it. PlayerScreen (the TV) draws over it; the phone's player will too.
///
/// Every property is @Published where it was @State, so a write redraws the view exactly as before.
/// The clock, the exit snapshotter and the Now Playing id stay plain lets: they were plain @State
/// objects that never changed, and nothing may observe them from the body.
/// The one thing the view keeps is the focus ring (a @FocusState); the session reaches it through
/// `bindFocus`.
@MainActor
final class PlayerSession: ObservableObject {
    // MARK: inputs (what the caller handed the player)
    let title: String

    let subtitle: String?

    let url: URL

    let headers: [String: String]

    let context: PlaybackContext?

    /// "S1 E2 · Title" of what follows; drives the up-next card and Next episode (bp-up-next.tsx).
    let upNext: String?

    /// Live streams: live mpv cache options, no seek bar, no progress saves.
    let isLive: Bool

    /// The picked stream's facts for the Auto engine rule (engine/player.ts pickEngine); nil plays
    /// by URL alone (live channels, sports links).
    let streamHints: PlayerStreamHints?

    /// source-error-card "Pick another source": the caller reopens the picker after this closes.
    /// Only where the in-place switcher cannot swap (canSwitchInPlace).
    let onChooseAnother: (() -> Void)?

    /// bp-player-sources "Switch source": reopen the picker and resume the new stream here.
    /// Only where the switcher cannot swap in place (canSwitchInPlace: a home-server copy).
    let onSwitchSource: ((Double) -> Void)?

    /// bp-player-controls "Previous episode": the caller opens the previous episode's picker.
    /// "Next episode" needs nothing new: closing with `true` is how the caller advances.
    let onPreviousEpisode: (() -> Void)?

    /// Live TV (use-live-channel-overlay.ts): the source the channel came from. It turns on the
    /// transport's "TV Guide" (switch channel in place) and "Previous channel".
    let liveGuide: LiveModel?

    /// The channel being played, when it came from `liveGuide`.
    let liveChannel: LiveModel.Channel?

    /// "Add to Multiview": the caller closes the player and opens Multiview with this channel.
    let onAddToMultiview: ((LiveModel.Channel) -> Void)?

    /// view.ts PlayerSrc autoFired / attempt / streamRef: how the picker handed this stream over
    /// (nil when no picker did).
    let pick: PlayerPickInfo?

    /// views/player.tsx / use-player-exit.ts openPicker(meta, episode, { autoPlay, attempt: attempt + 1 }):
    /// once this player has closed, the caller reopens the picker, firing on its own when `auto`.
    /// Without it the player never sends a stream back (stall skip, stub detection).
    let onPickAgain: ((_ auto: Bool) -> Void)?

    /// Picture in Picture may step this screen aside for the browse layer (Player/PiPBrowse.swift).
    /// Multiview's full-screen player keeps the placard instead: its grid is under it.
    let browseDuringPiP: Bool

    /// view.ts PlayerSrc.subtitles: the subtitles the resolved stream came with (an addon stream's
    /// `subtitles`, a home server's external files). Each player this screen makes adds them
    /// unselected once the file is open (mpv.ts addSeedSubtitles), so a retry or the move to mpv
    /// brings them again (use-auto-retry passes src.subtitles on every reload).
    let streamSubtitles: [SeedSubtitle]

    /// The PlayEpisode the picker searched with (view.ts PlayerSrc.episode): the in-player
    /// switcher searches with it again. nil builds one from the context.
    let pickEpisode: AnyJSON?

    /// (S4) view.ts PlayerSrc.subtitlePreselect: the picker's subtitle step chose this (TrackMemory.preselect).
    let subtitlePreselect: SubtitlePreselect?

    let onClose: (_ endedNaturally: Bool) -> Void

    // MARK: state
    /// use-live-channel-overlay switchChannel: the channel tuned in place (nil = the one opened).
    @Published var tuned: LiveModel.Channel?

    /// goPrevChannel: the channels tuned before, newest last, 12 at most.
    @Published var prevChannels: [LiveModel.Channel] = []

    /// KidsStreamSwitcher onPick: the stream picked in place of the one opened (nil = the one opened).
    @Published var switched: SwitchedStream?

    /// A quality switch made while paused starts the new stream paused (bp-ten-foot startPaused: !playing).
    @Published var pausedAfterSwitch = false

    /// Whether the stream was swapped in place (the kid switcher, a quality change): TrackMemory keys by the original release otherwise.
    var switchedInPlace: Bool { switched != nil }

    struct SwitchedStream {
        var url: URL
        var headers: [String: String]
        /// The swapped-in stream's own subtitles (use-stream-switcher / switchMediaServerQuality `subtitles: next.subtitles`).
        var subtitles: [SeedSubtitle] = []
        /// use-stream-switcher liveStreamRef: the picked stream's PlayerStreamRef, when the
        /// switcher knew it (its "Now playing" row and the room's source descriptor).
        var ref: AnyJSON? = nil
        /// The swapped-in release's file name, when the source switcher
        /// knew it (liveStreamRef.resolvedFilename): the subtitle memory's release key follows it.
        var filename: String? = nil
    }

    /// views/player.tsx subtitleStreamKey(activeMediaSrc.streamRef): after a
    /// swap in place the release is the new stream's (TrackMemory.swift), nil when it is not known.
    var switchedFilename: String? { switched?.filename }

    /// TransportKids' subtitle toggle reads the subtitle tracks (refreshed while its chrome is up).
    @Published var kidSubs: [MPVPlayerController.Track] = []

    @Published var subDelay: Double = 0

    /// bp-player-sources BpAudioLane: mpv audio-delay, ±0.1 / ±0.5 s.
    @Published var audioDelay: Double = 0

    /// bp-player-rail mute chip.
    @Published var muted = false

    /// bp-player-scrub nudge(): presses accumulate into one seek committed 420 ms after the last.
    @Published var pendingSeek: Double?

    /// Touch-surface scrubbing (scrubSwipe): where the swipe began, and when it last moved.
    @Published var scrubBase: Double?

    @Published var lastScrubAt = Date.distantPast

    @Published var seekRun = 0

    @Published var seekCommit: Task<Void, Never>?

    /// player.tsx autoNextCancelled: "Keep watching" on the up-next card.
    @Published var autoNextCancelled = false

    @Published var prefs = PlayerPrefs()

    @Published var finishing = false

    @Published var loadingSince = Date()

    @Published var reloadToken = 0

    /// use-auto-end-exit.ts reloadTimesRef: when a live channel that ran out was reloaded (15 s window).
    @Published var liveReloadTimes: [Date] = []

    /// The pending reload (or close) after a live channel ran out.
    @Published var liveEndTask: Task<Void, Never>?

    /// use-auto-retry.ts liveRetryCountRef / livePlayedRef: the reconnects made
    /// for this channel, and whether it ever played (which allows a second one). Reset per channel.
    @Published var liveRetries = 0

    @Published var livePlayed = false

    /// The pending live reconnect (its timer, 1.5 s or 4 s).
    @Published var liveRetryTask: Task<Void, Never>?

    /// use-auto-retry.ts truncatedReloadedRef: this source already came
    /// back once after ending well before its length (a dropped connection).
    @Published var truncatedReloaded = false

    /// A second early end of the same source: the source error card says so, instead of a frozen
    /// last frame with nothing to press (use-auto-retry triggerAutoRetry's sourceError).
    @Published var endedEarly: String?

    /// use-started-near-end.ts: the stream the first playing reading was taken for, and whether
    /// that reading was at 80% or later (NEAR_END_RATIO). Keyed by upstream's src.url (srcURL).
    @Published var nearEndCapturedFor: URL?

    @Published var startedNearEnd = false

    /// views/player.tsx replacePlayerSrc: the stream a home-server quality
    /// switch put in place of the PlayerSrc (switchMediaServerQuality), which gives it a new src.url.
    /// The source switcher and the kid switcher swap only use-stream-switcher's liveUrl (src.url stays).
    @Published var replacedSrc: URL?

    @Published var status = MPVPlayerController.Status()

    @Published var chrome = true

    @Published var hideTask: Task<Void, Never>?

    @Published var controller: (any PlayerEngineControlling)?

    /// use-player-bridge.ts engine: mpv, or AVPlayer standing in for html5. Settled before startAt.
    @Published var engine: PlayerEngineKind = .mpv

    /// settings.playerEngine as read for this stream ("auto" | "mpv" | "html5").
    @Published var engineWant = "auto"

    /// use-player-bridge.ts autoFallbackTried: the native engine failed once; mpv has it now.
    @Published var engineFallbackTried = false

    /// player.tsx showNoAudioWarning: the native engine plays but cannot decode the audio.
    @Published var noAudioWarning = false

    /// use-pip-mode.ts pipMode: the picture is in the Picture in Picture window (AVPlayer engine only).
    @Published var pipActive = false

    /// The phone's player keeps playing when the app leaves the screen (background audio,
    /// PiP); the TV's still pauses (didEnterBackground). Set by the phone's view.
    var keepsPlayingInBackground = false
    /// What the readout says on return when a torrent stream stopped while the app was away.
    @Published var backgroundNote: String?

    /// This player was opened from the PiP browse layer (it lives in that window): its own PiP
    /// keeps the placard, the layer never stacks on itself.
    @Published var inBrowseLayer = false

    @Published var openedOnce = false

    /// Every start position set here arms the resume save guard (ResumeSaveGuard.swift):
    /// no save goes out until playback has reached it.
    @Published var startAt: Double? {
        didSet { resumeGuard.arm(startAt) }
    }

    /// bp-resume-prompt: the saved position waits for "Pick up where you left off" / "Start over" (settings.resumePrompt).
    /// The fork's spot arms the guard too: the engine waits at 0 under it.
    @Published var resumePending: Double? {
        didSet { resumeGuard.arm(resumePending) }
    }

    /// Holds progress saves until playback has started at the spot it was sent to. Plain (not
    /// @Published): nothing draws it.
    var resumeGuard = ResumeSaveGuard()

    /// bp-leave-confirm: Back asks "Leave the show?" (settings.playerConfirmLeave) unless the viewer said don't ask again.
    @Published var leaveConfirm = false

    @Published var leaveRemember = false

    /// The video was playing when Back asked "Leave the show?". Only then do Keep
    /// watching and Menu start it again (upstream never pauses for the dialog); a viewer who had
    /// paused first had the film start playing under them.
    @Published var leaveResumes = false

    /// The rail chip that opened the panel: the ring goes back to it when the panel
    /// closes, as use-bp-focus restores the route's last position (it was left on the stage).
    @Published var panelOpener: FocusTarget?

    @Published var lastSavedPos: Double = -10

    /// The 1 s tick's snapshot, the buffered end and lastGoodPos (PlayerClock.swift).
    /// A plain @State holding the object, not a @StateObject: this body never observes it; the
    /// leaves that show time do (PlayerClockReader). Logic reads `clock.snap` directly.
    let clock = PlayerClock()

    /// use-exit-snapshot.ts: the frame kept for the Continue Watching card (ExitSnapshot.swift).
    /// A plain @State holding the object, like the clock: nothing draws from it.
    let exitSnapshot = ExitSnapshotter()

    /// The pause flag for this body's layout (the Play/Pause chip, X-Ray, the hide
    /// timer's onChange), written only when it changes (takeSnap).
    @Published var isPaused = false

    /// Bumped by the tick while a stream is loading: the connecting card's elapsed
    /// time and its 2 s threshold are read off the clock, and nothing else redraws this body on
    /// time alone now (the engines' 1 s status report is stored only on a change, applyStatus).
    @Published var loadingBeat = 0

    @Published var panel: Panel?

    @Published var segments: [SkipSegment] = []

    /// What the skip segments were last asked for: the duration and the file's chapter count.
    @Published var segmentsLoadedFor = ""

    @Published var segmentsDuration = -1

    /// Only the newest skip.segments answer lands (an older duration's lookup can finish last).
    @Published var segmentsRun = 0

    /// skip-pill-container.tsx autoSkippedRef: the segment already auto-skipped (never twice, even
    /// when the viewer seeks back into it).
    @Published var autoSkippedId: String?

    /// The segment the last tick saw playing: auto-skip waits for a second tick inside it, so a
    /// position read before a resume seek lands never skips the viewer away from their spot.
    @Published var autoSkipSeen: String?

    /// skip-pill-container.tsx autoHiddenKey / dismissedKeys / prevSkipKeyRef: the pill hidden after
    /// skipButtonHideSec, or by its ✕, for the segment it belongs to.
    @Published var skipAutoHiddenKey: String?

    @Published var skipDismissedKeys: Set<String> = []

    @Published var prevSkipKey: String?

    @Published var skipHideTask: Task<Void, Never>?

    /// use-still-watching.ts prompt: the auto-advance waits on "Still watching?".
    @Published var stillPrompt = false

    /// xray-overlay.tsx (PlayerXRay.swift): X-Ray's browser, a person page or a trailer covers the player.
    @Published var xrayOpen = false

    /// speed-menu.tsx rate (bridge setRate); a title starts at settings.defaultPlaybackSpeed.
    @Published var rate: Double = 1

    // use-sleep-timer.ts: the app-wide sleep timer is on the Speed & sleep control's face, which
    // observes it itself (PlayerSleepReader): its countdown no longer redraws this body each second.
    /// lib/media-session.ts: this player's claim on Now Playing and the remote commands.
    let nowPlayingId = UUID()

    /// views/player.tsx playbackStartedRef: a pause, a position or a picture was seen, so this stream
    /// is never skipped as stalled.
    @Published var playbackStarted = false

    /// views/player.tsx autoAdvancedRef: this player already sent its stream back to the picker.
    @Published var sentBack = false

    /// views/player.tsx: the stall wait runs from the stream's load (the player opening).
    @Published var openedAt = Date()

    /// use-stub-detection.ts stubCheckedRef: the stub check ran for this stream.
    @Published var stubChecked = false

    struct SkipSegment: Decodable, Identifiable {
        var kind: String       // "intro" | "outro" | "recap" | "ad" | ...
        var startSec: Double
        var endSec: Double
        var source: String
        var id: String { "\(kind)-\(startSec)-\(endSec)" }
        var label: String {
            switch kind {
            case "intro": return "Skip Intro"
            case "outro", "credits": return "Skip Credits"
            case "recap": return "Skip Recap"
            case "ad": return "Skip injected ad?"
            default: return "Skip \(kind)"
            }
        }
    }

    /// engine player.prefs: settings/defaults.ts nextEpisodeLeadSec, autoPlayNextEpisode, seek steps.
    struct PlayerPrefs: Decodable {
        var autoPlayNextEpisode = true
        var nextEpisodeLeadSec: Double = -1
        var seekBackStepSec: Double = 10
        var seekForwardStepSec: Double = 10
        /// views/player.tsx: skip an auto-picked stream that has not started after the wait
        /// (lib/player/stall-wait.ts stallWaitSec, clamped by the engine).
        var autoNextStreamOnStall = false
        var autoNextStreamOnStallSec: Double = 10
        /// use-stub-detection.ts runs under settings.instantPlay.
        var instantPlay = true
    }

    enum Panel { case audio, subtitles, anime4k, channels, kidsSources, homeServerQuality, speed, sources }

    struct Anime4KChoice: Decodable { var active: Bool; var choice: String; var mode: String?; var tier: String?; var files: [String]; var indicator: Bool }

    @Published var anime4k: Anime4KChoice?

    @Published var anime4kAppliedFor: Int = -1

    @Published var anime4kNote: String?

    /// Only the newest anime4k.choose run hands mpv its chain.
    @Published var anime4kRun = 0

    enum FocusTarget: Hashable { case surface, chip(String), track(Int) }

    @Published var scrobbleState: String?   // last action sent to Trakt

    @Published var lastScrobblePaused = false

    static let hideAfter: Double = 4.6   // use-bp-player-chrome.ts
    /// The chrome's idle hide for this player: the TV's 4.6 s, the phone's HUD 3 s.
    var hideDelay: Double = PlayerSession.hideAfter

    // MARK: focus (the view's @FocusState, reached through closures)

    private var focusReader: () -> FocusTarget? = { nil }
    private var focusWriter: (FocusTarget?) -> Void = { _ in }
    /// The ring's current target; writing it moves the ring. Both go to the view's @FocusState.
    var focus: FocusTarget? {
        get { focusReader() }
        set { focusWriter(newValue) }
    }

    /// The view hands over its @FocusState (capturing only the state, never the view or the session).
    func bindFocus(read: @escaping () -> FocusTarget?, write: @escaping (FocusTarget?) -> Void) {
        focusReader = read
        focusWriter = write
    }

    init(title: String,
         subtitle: String?,
         url: URL,
         headers: [String: String] = [:],
         context: PlaybackContext? = nil,
         upNext: String? = nil,
         isLive: Bool = false,
         streamHints: PlayerStreamHints? = nil,
         onChooseAnother: (() -> Void)? = nil,
         onSwitchSource: ((Double) -> Void)? = nil,
         onPreviousEpisode: (() -> Void)? = nil,
         liveGuide: LiveModel? = nil,
         liveChannel: LiveModel.Channel? = nil,
         onAddToMultiview: ((LiveModel.Channel) -> Void)? = nil,
         pick: PlayerPickInfo? = nil,
         onPickAgain: ((_ auto: Bool) -> Void)? = nil,
         browseDuringPiP: Bool = true,
         streamSubtitles: [SeedSubtitle] = [],
         pickEpisode: AnyJSON? = nil,
         subtitlePreselect: SubtitlePreselect? = nil,
         onClose: @escaping (_ endedNaturally: Bool) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.headers = headers
        self.context = context
        self.upNext = upNext
        self.isLive = isLive
        self.streamHints = streamHints
        self.onChooseAnother = onChooseAnother
        self.onSwitchSource = onSwitchSource
        self.onPreviousEpisode = onPreviousEpisode
        self.liveGuide = liveGuide
        self.liveChannel = liveChannel
        self.onAddToMultiview = onAddToMultiview
        self.pick = pick
        self.onPickAgain = onPickAgain
        self.browseDuringPiP = browseDuringPiP
        self.streamSubtitles = streamSubtitles
        self.pickEpisode = pickEpisode
        self.subtitlePreselect = subtitlePreselect
        self.onClose = onClose
    }

    /// player.tsx hasNextEpisodeNow (use-queue-nav: adjacent.next): there is an episode after this
    /// one ("Keep watching" aside).
    var hasNextEpisodeNow: Bool { upNext != nil && !isLive }

    /// use-queue-nav hasPrevEpisodeNow = adjacent.prev.
    var hasPrevEpisodeNow: Bool { onPreviousEpisode != nil && !isLive }

    /// bp-player-sources: where "Switch source" resumes the new stream. mpv
    /// reports 0 / 0 once its stream has died, so the error card's Switch source restarted the title
    /// at 0:00: the last spot the picture reached stands in, else the spot this player opened at.
    var switchSpot: Double {
        if clock.snap.duration > 0, clock.snap.position > 0 { return clock.snap.position }
        return clock.lastGoodPos > 0 ? clock.lastGoodPos : (startAt ?? 0)
    }

    /// The transport is on screen (the body's condition; Back puts it away first).
    /// Not under the connecting card either: bp-connecting is an overlay
    /// over the shell, and both drew on the same bottom band (title and transport showing through
    /// "Connecting…", their chips focusable under it) from 2 s until the chrome timed out.
    var chromeShown: Bool {
        chrome && !pipActive && resumePending == nil && !leaveConfirm && !kidsLoading && !stillPrompt && !xrayOpen
            && (panel == nil || panel == .anime4k) && !failed && !connectingShown
    }

    /// The stream failed: the engine's error, or a second early end (truncatedEnd).
    var failed: Bool { status.state == "error" || endedEarly != nil }

    /// bp-connecting: a start that is taking a while (2 s on); a kid gets the sea loader instead.
    var connectingShown: Bool {
        // Read so the tick's loadingBeat redraws the body while loading: the 2 s
        // threshold and the card's elapsed seconds are wall-clock reads.
        _ = loadingBeat
        return status.state == "loading" && !isKid && !isLive && !pipActive && resumePending == nil && panel == nil && !leaveConfirm
            && Date().timeIntervalSince(loadingSince) >= 2
    }

    /// This TV's Anime4K choice ("off", "auto" or a mode), kept on the device, never synced.
    static let anime4kKey = "harbor.tv.anime4k"

    var isKid: Bool { ProfilesStore.shared.active?.kid != nil }

    /// player.tsx canPickAnother, for a title the kid switcher can search again.
    var kidsCanSwitch: Bool {
        guard let context, !isLive else { return false }
        return !context.playlistVod && context.homeServer == nil
    }

    /// cinematic-player-loader.tsx `showing` for a kid: from the start until the stream plays (a
    /// switched video, a retry or a new source starts it again), never over the resume fork, an
    /// error, a live channel (its own card).
    var kidsLoading: Bool {
        guard isKid, !isLive, !pipActive, resumePending == nil, !stillPrompt else { return false }
        return status.state == "idle" || status.state == "loading"
    }

    var currentChannel: LiveModel.Channel? { tuned ?? liveChannel }

    var playURL: URL { tuned.flatMap { URL(string: $0.url) } ?? switched?.url ?? url }

    /// views/player.tsx src.url: the channel tuned in place, a home-server
    /// quality's new PlayerSrc, else the stream opened. Not a stream swapped in place by the source
    /// or kid switcher (use-stream-switcher liveUrl): use-started-near-end and use-content-advisory
    /// key on src.url, so neither takes a new reading or shows again for such a swap.
    var srcURL: URL { tuned.flatMap { URL(string: $0.url) } ?? replacedSrc ?? url }

    var playHeaders: [String: String] { tuned.map { $0.headers ?? [:] } ?? switched?.headers ?? headers }

    /// PlayerSrc.subtitles of what plays now: a tuned channel has none, a stream swapped in place
    /// brings its own (not the opened stream's), otherwise the opened stream's.
    var playSeeds: [SeedSubtitle] {
        if tuned != nil { return [] }
        if let switched { return switched.subtitles }
        return streamSubtitles
    }

    var shownTitle: String { tuned?.name ?? title }

    var shownSubtitle: String? {
        guard let t = tuned else { return subtitle }
        return liveGuide?.guide[t.id]?.now?.title ?? t.group
    }

    func open(_ p: Panel) {
        // The chip pressed to open it, when it sits on the transport.
        if case .chip(_)? = focus, chromeShown { panelOpener = focus } else { panelOpener = nil }
        panel = p
        hideTask?.cancel()
        // The Subtitles and Audio dialogs seed their own ring; Anime4K lands on its first option.
        // On the option in use (anime4k-menu marks it), not always Auto; the ids
        // are anime4kPanel's options, in its order.
        if p == .anime4k {
            let ids: [String] = ["auto", "off", "A", "B", "C", "AA", "BB", "CA"]
            let at: Int = ids.firstIndex(of: anime4k?.choice ?? "auto") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in focus = .track(-10 - at) }
        }
    }

    func closePanel() {
        let back = panelOpener
        panelOpener = nil
        panel = nil
        focus = .surface
        wake()
        // bp-player-shell closePanel → the route's remembered position: the ring
        // goes back to the chip that opened the panel once the transport is on screen again. It
        // stayed on the invisible stage, so Select paused instead of reopening Subtitles.
        guard let back else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            let untouched: Bool = focus == nil || focus == .surface
            if panel == nil, chromeShown, untouched { focus = back }
        }
    }

    /// Every snapshot goes through here: the clock stores it (its leaves redraw only
    /// on a change) and this body's `isPaused` follows only a real change of the pause flag.
    func takeSnap(_ s: (position: Double, duration: Double, paused: Bool)) {
        clock.update(s)
        if isPaused != s.paused { isPaused = s.paused }
    }

    /// Both engines report their status every second, with a position / cache readout
    /// (fps, dropped) this screen never shows: storing each report redrew the whole player every
    /// second. It is stored when something the player reads changes (state, picture, error, log).
    func applyStatus(_ s: MPVPlayerController.Status) {
        let same: Bool = s.state == status.state && s.videoParams == status.videoParams && s.error == status.error
            && s.log == status.log && s.hwdec == status.hwdec
        if !same { status = s }
    }

    /// The remote's Play/Pause (and the system's play / pause commands).
    /// Under the resume fork it takes the ring's choice (Resume unless the ring is on
    /// Start over), under "Leave the show?" it is Keep watching, playing: it toggled the video under
    /// both, so the film began from 0:00 behind "Pick up where you left off", or played under the
    /// leave dialog.
    func playPausePressed() {
        guard !finishing else { return }
        if resumePending != nil {
            let startOver: Bool = focus == .chip("Start over")
            acknowledgeResume(!startOver)
        } else if leaveConfirm {
            leaveResumes = true
            keepWatching()
        } else {
            togglePause()
        }
    }

    func togglePause() {
        // A closing player stays paused (finish): Select on the stage started it again.
        guard !finishing else { return }
        controller?.togglePause()
        if let c = controller { takeSnap(c.snapshot()) }
        // X-Ray lives while paused: playing again closes its browser / person page.
        if !clock.snap.paused { xrayOpen = false }
        wake()
    }

    /// player-overlay-layers.tsx mounts XrayOverlay unless PiP (or drawing) and shows it with the
    /// chrome; the TV opens it on pause and keeps it clear of every prompt and panel. Kids get it too (upstream does not gate it), when their profile turned it on.
    var xrayMeta: Meta? {
        // Not for kid profiles: X-Ray opens person pages with unfiltered filmographies (upstream doesn't gate it).
        guard SettingsBridge.shared.slice.xrayEnabled ?? false, !isKid, isPaused, chrome || xrayOpen, let meta = context?.meta,
              panel == nil, !leaveConfirm, resumePending == nil, !pipActive, !stillPrompt, !kidsLoading,
              !failed else { return nil }
        return meta
    }

    func wake() {
        // use-still-watching.ts: any press in the player starts the episode count over.
        StillWatching.reset()
        chrome = true
        scheduleHide()
    }

    /// use-sleep-timer.ts fire handler (bridge.pause()); the chrome comes up so the pause shows.
    func sleepFired() {
        if let c = controller, !c.snapshot().paused { c.setPaused(true) }
        if let c = controller { takeSnap(c.snapshot()) }
        chrome = true
        scheduleHide()
    }

    /// media-session.ts / use-keyboard-shortcuts.ts media keys: what the system's commands do here.
    func beginNowPlaying() {
        // The actions live in the Now Playing singleton: they hold the session weakly.
        var previous: (() -> Void)? = nil
        if hasPrevEpisodeNow { previous = { [weak self] in self?.previousEpisode() } }
        var next: (() -> Void)? = nil
        if hasNextEpisodeNow { next = { [weak self] in self?.playNext() } }
        let actions = VideoNowPlaying.Actions(
            isPlaying: { [weak self] in self?.controller.map { !$0.snapshot().paused } ?? false },
            toggle: { [weak self] in self?.playPausePressed() },
            seekStep: { [weak self] delta in
                guard let self else { return }
                if isLive { controller?.seek(delta) } else { seekBy(delta) }
            },
            seekTo: { [weak self] sec in
                guard let self, !isLive else { return }
                seekBy(sec - clock.snap.position)
            },
            next: next,
            previous: previous)
        VideoNowPlaying.shared.begin(nowPlayingId, actions: actions, seekBack: prefs.seekBackStepSec, seekForward: prefs.seekForwardStepSec)
    }

    /// player.tsx updateMediaControls: title, "S1 E2 · name", art (backdrop, else poster; a
    /// channel's logo), duration, position and whether it is playing.
    func nowPlayingTick() {
        let playing = status.state == "playing" && (isLive || clock.snap.position > 0.3)
        let meta = context?.meta
        let art = isLive ? currentChannel?.logo : (meta?.background ?? meta?.poster)
        VideoNowPlaying.shared.update(nowPlayingId, playing: playing, title: shownTitle, subtitle: shownSubtitle, artURL: art,
                                      durationSec: clock.snap.duration, positionSec: clock.snap.position, rate: rate, isLive: isLive)
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [self] in
            try? await Task.sleep(for: .seconds(hideDelay))
            // Not under a fork, a prompt or an error card (upstream's
            // `pinned`): the ring was pulled off "Keep watching" / "Leave" and the error card's
            // choices onto the stage (a disabled one under the prompts), after any press woke it.
            guard !Task.isCancelled, panel == nil, !pipActive, !clock.snap.paused,
                  resumePending == nil, !leaveConfirm, !stillPrompt, !failed else { return }
            chrome = false
            // A card that stays up without the chrome (connecting, no audio, the kid loader) keeps its ring.
            if !ringOnCard { focus = .surface }
        }
    }

    /// The ring is on a card that outlives the chrome.
    /// The skip pill and the up-next card are such cards too, like the
    /// other cards beside them: Up from the woken transport reaches them, and the idle
    /// hide took the ring back to the stage 4.6 s later while the pill stayed up, so the Select
    /// meant for "Skip Intro" or "Play now" paused the film instead.
    var ringOnCard: Bool {
        guard case .chip(let id)? = focus else { return false }
        let cards: [String] = ["Go back", "Try again", "Switch source", "Use mpv engine", "Dismiss", "kids-cancel", "kids-goback", "kids-retry",
                               "skip", "skip-dismiss", "upnext-play", "upnext-keep"]
        guard cards.contains(id) else { return false }
        // Only while that cue is drawn: the pill turns into the up-next card inside the
        // lead (and the card goes back to the pill on a seek out of it), so a ring left on the one
        // that went is taken back to the stage by the hide, not kept on nothing.
        if id == "skip" || id == "skip-dismiss" { return activeSkip != nil && !showUpNextCard }
        if id == "upnext-play" || id == "upnext-keep" { return showUpNextCard }
        return true
    }

    // The save and report throttles: nothing draws from them, so they are plain vars (not @Published).
    var lastSaveAt = Date.distantPast

    var lastSavePaused = false

    var lastHomeReport: Double = 0

    var lastHomePaused = false

    /// A focus target that is only being inserted this tick cannot take the ring yet.
    func focusLater(_ target: FocusTarget) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in focus = target }
    }
}
