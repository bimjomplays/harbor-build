import SwiftUI
import UIKit

/// The Player setting, one per profile: Harbor's own player (nil, the default) or an external player
/// (ExternalPlayer). Saved under `phone.player.<profileId>` like the phone's other per-profile settings.
/// It is Settings → Player (PhoneSettingsPage.player).
enum PhonePlayerChoice {
    static let keyPrefix = "phone.player."
    static let builtIn = "builtin"

    static func key(for profileId: String) -> String { keyPrefix + profileId }

    /// The saved external player; nil for Harbor's own (nothing saved, or "builtin").
    static func saved(for profileId: String) -> ExternalPlayer? {
        Prefs.get(String.self, for: key(for: profileId)).flatMap(ExternalPlayer.init(rawValue:))
    }

    static func save(_ player: ExternalPlayer?, for profileId: String) {
        try? Prefs.set(player?.rawValue ?? builtIn, for: key(for: profileId))
    }

    @MainActor static var activeProfileId: String { ProfilesStore.shared.active?.id ?? "default" }
}

/// Hands picked streams to an external player: the installed players, the Player
/// setting, the play picker's "Open in…", and the player's way back (x-success / x-error).
///
/// A pick reaches `PhonePlay.handOff(stream:)` resolved, as for Harbor's player; `take(_:)` decides
/// first. The row's "Open in…" aims the next pick of that row at a player (`aim(_:at:)`), else the
/// Player setting decides. A link another app cannot reach (ExternalReach) stays in Harbor: from
/// "Open in…" the picker says why and stays; under the setting, Harbor's player takes it.
@MainActor
final class PhoneExternalPlay: ObservableObject {
    static let shared = PhoneExternalPlay()

    /// Where one pick goes.
    enum Target: Equatable {
        /// The Player setting.
        case setting
        /// Harbor's own player, whatever the setting.
        case builtIn
        case player(ExternalPlayer)
    }

    /// The players `canOpenURL` finds, in registry order (Infuse first).
    @Published private(set) var installed: [ExternalPlayer] = []
    /// The picker's note: why a stream stayed in Harbor, or that a player would not open.
    @Published var notice: String?
    /// The Player setting changed (the Settings rows redraw).
    @Published private(set) var revision = 0

    /// The next pick of this row goes to this target.
    private var aimed: (streamId: String, target: Target)?
    /// Hand-offs waiting on their player's way back, by the token in the callback URL.
    private var sessions: [String: Session] = [:]

    private struct Session {
        let player: ExternalPlayer
        let context: PlaybackContext
    }

    /// Under fixtures the choice lives only as long as the launch, so one UI test's pick never reaches
    /// the next (the fixture profiles keep their ids from launch to launch).
    private var fixtureChoices: [String: ExternalPlayer] = [:]

    /// Asks `canOpenURL` again (a player may have been installed or removed since).
    func refresh() {
        installed = Fixtures.active && PhoneLaunch.externalPlayers ? ExternalPlayer.allCases : ExternalPlayer.allCases.filter { UIApplication.shared.canOpenURL($0.probeURL) }
    }

    /// The active profile's saved choice, installed or not.
    var saved: ExternalPlayer? {
        let id = PhonePlayerChoice.activeProfileId
        return Fixtures.active ? fixtureChoices[id] : PhonePlayerChoice.saved(for: id)
    }

    /// The player picks go to: the saved one while it is installed, else nil (Harbor's player).
    var preferred: ExternalPlayer? {
        guard let p = saved, installed.contains(p) else { return nil }
        return p
    }

    func choose(_ player: ExternalPlayer?) {
        let id = PhonePlayerChoice.activeProfileId
        if Fixtures.active { fixtureChoices[id] = player } else { PhonePlayerChoice.save(player, for: id) }
        revision += 1
    }

    /// The picker's row press: the pick of `streamId` that follows goes to `target`.
    func aim(_ target: Target, at streamId: String) {
        aimed = (streamId, target)
        notice = nil
    }

    /// The picker closed: nothing stays aimed, the note goes.
    func reset() {
        aimed = nil
        notice = nil
    }

    // MARK: the hand-off

    /// Takes a resolved pick to an external player when one is asked for and can reach it; true when
    /// it did (or when "Open in…" was refused with a note), false when Harbor's player plays it.
    func take(_ handed: PhonePlayStream) -> Bool {
        let shot = aimed
        aimed = nil
        let target: Target = (shot != nil && shot?.streamId == handed.stream?.id) ? shot!.target : .setting
        let player: ExternalPlayer?
        switch target {
        case .setting: player = preferred
        case .builtIn: player = nil
        case .player(let p): player = p
        }
        guard let player else { return false }
        let asked: Bool = target != .setting
        let link = handed.resolved.data
        let reach = ExternalReach.check(url: link?.url ?? "", headers: link?.headers, via: handed.resolved.via,
                                        homeServer: handed.resolved.homeServer != nil || handed.stream == nil)
        guard case .reachable(let url) = reach else {
            // A home-server copy under the setting plays in Harbor as the Player footer says; the rest get a note.
            if asked || reach != .homeServer { notice = reach.reason }
            if asked { PhoneFeedback.shared.warning() }
            return asked
        }
        notice = nil
        Task { await open(player, url: url, handed: handed) }
        return true
    }

    private func open(_ player: ExternalPlayer, url: URL, handed: PhonePlayStream) async {
        let ctx = Self.context(handed)
        let resumeOn: Bool = SettingsBridge.shared.slice.resumePlayback ?? true
        // Fixtures leave the engine alone: the picker's fixture streams have no progress behind them.
        let resume: Double = resumeOn && !Fixtures.active ? await ctx.startPosition() : 0
        let token = UUID().uuidString
        let request = ExternalPlayer.Request(
            url: url,
            subtitle: player.takesSubtitle ? Self.subtitle(handed) : nil,
            filename: Self.filename(handed),
            positionSec: player.takesPosition ? Int(resume) : nil,
            onSuccess: URL(string: "harbor://\(Self.playedHost)/\(token)"),
            onError: URL(string: "harbor://\(Self.failedHost)/\(token)"))
        guard let target = player.playURL(request), await UIApplication.shared.open(target) else {
            notice = T("Couldn't open %@.", player.name)
            PhoneFeedback.shared.failure()
            return
        }
        sessions[token] = Session(player: player, context: ctx)
        PhoneFeedback.shared.success()
        PhonePlay.shared.pending = nil
        PhoneToaster.shared.show(T("Opening in %@", player.name))
        // The title shows as started: Continue Watching and the page's Resume. A title with a resume
        // spot keeps it (the player started there).
        if resume <= 0, !Fixtures.active { await Self.saveLocal(ctx, positionSec: Self.startedSec) }
    }

    /// engine/player.ts MIN_POSITION_SEC: the shortest position the engine keeps as started.
    nonisolated static let startedSec: Double = 5

    static func context(_ handed: PhonePlayStream) -> PlaybackContext {
        let ep = handed.episode
        let tt: Bool = handed.meta.id.hasPrefix("tt")
        return PlaybackContext(meta: handed.meta,
                               season: ep?["season"]?.number.map { Int($0) }, episode: ep?["episode"]?.number.map { Int($0) },
                               videoId: ep?["videoId"]?.string, imdbId: tt ? handed.meta.id : nil, imdbVerified: tt)
    }

    /// The subtitle step's choice, when it is a file another app can fetch.
    private static func subtitle(_ handed: PhonePlayStream) -> URL? {
        guard let choice = handed.resolved.subtitlePreselect, !choice.off, let raw = choice.url else { return nil }
        if case .reachable(let url) = ExternalReach.check(url: raw, headers: nil, via: nil, homeServer: false) { return url }
        return nil
    }

    /// The file's name (Infuse reads its metadata from it), else the title and episode.
    private static func filename(_ handed: PhonePlayStream) -> String {
        if let f = handed.resolved.data?.filename, !f.isEmpty { return f }
        let ep = handed.episode
        if let s = ep?["season"]?.number, let e = ep?["episode"]?.number {
            func two(_ n: Double) -> String { let i = Int(n); return i < 10 ? "0\(i)" : "\(i)" }
            return "\(handed.meta.name) S\(two(s))E\(two(e))"
        }
        if let year = handed.meta.releaseInfo, !year.isEmpty { return "\(handed.meta.name) (\(year))" }
        return handed.meta.name
    }

    // MARK: progress

    /// A position with no duration: the engine's local resume spot and Continue Watching entry only.
    /// PlaybackContext.save would also write the Stremio library, whose entry would get a 0 duration.
    private static func saveLocal(_ ctx: PlaybackContext, positionSec: Double) async {
        var slim: [String: AnyJSON] = ["id": .string(ctx.meta.id), "type": .string(ctx.meta.type), "name": .string(ctx.meta.name)]
        if let poster = ctx.meta.poster { slim["poster"] = .string(poster) }
        if let background = ctx.meta.background { slim["background"] = .string(background) }
        var input: [String: AnyJSON] = [
            "meta": .object(slim),
            "positionMs": .number((positionSec * 1000).rounded()),
            "durationMs": .number(0),
            "flush": .bool(false),
        ]
        if let season = ctx.season { input["season"] = .number(Double(season)) }
        if let episode = ctx.episode { input["episode"] = .number(Double(episode)) }
        if let videoId = ctx.videoId { input["videoId"] = .string(videoId) }
        _ = try? await HarborEngine.shared.callJSON("player.saveProgress", [.object(input)])
    }

    // MARK: the way back

    nonisolated static let playedHost = "external-played"
    nonisolated static let failedHost = "external-failed"

    /// What a player's callback says: harbor://external-played/<token>?position=…[&duration=…&status=…]
    /// (Infuse sends lastPlayedUrl and position, VidHub position, duration and status, VLC nothing), or
    /// harbor://external-failed/<token>?errorMessage=….
    struct Callback: Equatable {
        var failed: Bool
        var token: String?
        var positionSec: Double?
        var durationSec: Double?
        var finished: Bool
        var errorMessage: String?

        nonisolated static func parse(_ url: URL) -> Callback? {
            guard url.scheme?.lowercased() == "harbor", let host = url.host?.lowercased(),
                  host == playedHost || host == failedHost else { return nil }
            let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
            let token: String? = url.pathComponents.first { $0 != "/" }
            return Callback(failed: host == failedHost, token: token,
                            positionSec: value("position").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil },
                            durationSec: value("duration").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil },
                            finished: value("status") == "finished", errorMessage: value("errorMessage"))
        }
    }

    /// A harbor:// link from a player coming back; true when it was one (the deep-link router skips it).
    func handleCallback(_ url: URL) -> Bool {
        guard let back = Callback.parse(url) else { return false }
        let session: Session? = back.token.flatMap { sessions.removeValue(forKey: $0) }
        let name: String = session?.player.name ?? T("The player")
        if back.failed {
            PhoneToaster.shared.show(back.errorMessage.map { T("%@ couldn't play this stream: %@", name, $0) }
                                     ?? T("%@ couldn't play this stream.", name))
            return true
        }
        guard let session, let position = back.positionSec else { return true }
        Task {
            if let duration = back.durationSec {
                // With the length the engine can tell a finished film or episode: the full save.
                _ = await session.context.save(positionSec: back.finished ? duration : position, durationSec: duration, flush: true)
            } else if position >= Self.startedSec {
                await Self.saveLocal(session.context, positionSec: position)
            }
        }
        return true
    }
}

/// The Player setting (Settings → Player): Harbor's own player, or any installed external player.
struct PhonePlayerSettingsView: View {
    @ObservedObject private var external = PhoneExternalPlay.shared
    @ObservedObject private var settings = SettingsBridge.shared

    var body: some View {
        let _ = external.revision
        let saved: ExternalPlayer? = external.saved
        let current: ExternalPlayer? = external.preferred
        Form {
            Section {
                choiceRow(title: T("Harbor (built-in)"), detail: T("Saves your progress as you watch"),
                          id: "player-choice-builtin", selected: current == nil) { external.choose(nil) }
                ForEach(external.installed) { p in
                    choiceRow(title: p.name, detail: nil, id: "player-choice-\(p.id)", selected: current == p) { external.choose(p) }
                }
            } header: {
                Text(verbatim: T("Play streams in"))
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    if external.installed.isEmpty {
                        Text(verbatim: T("No other video players are installed. Harbor can hand streams to Infuse, VLC or VidHub."))
                            .accessibilityIdentifier("player-none-installed")
                    }
                    if let saved, current == nil {
                        Text(verbatim: T("%@ isn't installed, so Harbor plays streams itself.", saved.name))
                            .accessibilityIdentifier("player-missing")
                    }
                    Text(verbatim: T("Other players don't report progress back while you watch. Harbor marks the title as started when it hands it over, and saves where you stopped if the player brings you back to Harbor (Infuse and VidHub do, VLC doesn't). Peer-to-peer streams and home server copies always play in Harbor. To send one stream to another player, touch and hold it in the source list."))
                        .accessibilityIdentifier("player-footer")
                }
            }
            // The TV's Settings → Playback switches (SettingsView "Playback"); the player reads all three.
            Section {
                playbackToggle("Resume where you left off", key: "resumePlayback", on: settings.slice.resumePlayback ?? true, id: "player-resume")
                playbackToggle("Ask before resuming", key: "resumePrompt", on: settings.slice.resumePrompt ?? false, id: "player-resume-prompt")
                playbackToggle("Confirm before leaving the player", key: "playerConfirmLeave", on: settings.slice.playerConfirmLeave ?? true, id: "player-confirm-leave")
            } header: {
                Text(verbatim: T("Playback"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Player"))
        .onAppear { external.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-settings")
    }

    private func playbackToggle(_ label: String, key: String, on: Bool, id: String) -> some View {
        Toggle(isOn: Binding(
            get: { on },
            set: { next in
                PhoneFeedback.shared.selection()
                Task { try? await settings.patch([key: .bool(next)]) }
            }
        )) {
            Text(verbatim: T(label))
        }
        .accessibilityIdentifier(id)
    }

    private func choiceRow(title: String, detail: String?, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            PhoneFeedback.shared.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(PhoneTheme.sans(17, .medium, relativeTo: .body)).foregroundStyle(BP.ink)
                    if let detail {
                        Text(verbatim: detail).font(PhoneTheme.sans(13, .regular, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(BP.accent).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }
}
