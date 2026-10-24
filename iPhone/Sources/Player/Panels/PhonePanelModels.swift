import SwiftUI

/// The state behind the phone player's panel sheets, with no view in them so the unit
/// tests reach them. The subtitles sheet reads the TV's own SubtitlesPanelModel; speed and sleep use
/// PhoneSpeedSleep and SleepTimer.shared; what is here is the audio lane, the home-server quality
/// choice and the stats read-out.

/// A track's two lines (bp-player-sources.tsx trackLines): its own name (or its language), then
/// language · codec · channels · Default.
enum PhoneTrackText {
    static func lines(_ t: MPVPlayerController.Track) -> (head: String, detail: String) {
        // Through languageName's 639-2 aliases ("ger" → German, not "GER").
        let lang: String = t.lang.map { TrackLanguage.englishName($0) ?? $0.uppercased() } ?? ""
        let trimmed: String = t.title?.trimmingCharacters(in: .whitespaces) ?? ""
        let named: String = (trimmed.isEmpty || trimmed == t.lang) ? "" : trimmed
        let detail: String = [lang, t.codec?.uppercased() ?? "", t.channels ?? "", t.isDefault ? T("Default") : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let head: String = !named.isEmpty ? named : (!lang.isEmpty ? lang : T("Track"))
        return (head, detail)
    }

    /// The HUD button's value for a track list: the track that is on, nil when none is.
    static func onLabel(_ tracks: [MPVPlayerController.Track], type: String) -> String? {
        tracks.first { $0.type == type && $0.selected }.map { lines($0).head }
    }
}

/// The audio sheet's tracks and sync offset (PlayerAudioPanel without the remote's focus ring).
@MainActor
final class PhoneAudioModel: ObservableObject {
    @Published private(set) var tracks: [MPVPlayerController.Track] = []
    @Published private(set) var delay: Double
    private(set) var controller: (any PlayerEngineControlling)?
    private let writeDelay: (Double) -> Void

    static let delaySteps: [Double] = [-0.5, -0.1, 0.1, 0.5]

    init(controller: (any PlayerEngineControlling)?, delay: Double, onDelay: @escaping (Double) -> Void) {
        self.controller = controller
        self.delay = delay
        self.writeDelay = onDelay
        tracks = Self.audio(of: controller)
    }

    private static func audio(of c: (any PlayerEngineControlling)?) -> [MPVPlayerController.Track] {
        (c?.tracks() ?? []).filter { $0.type == "audio" }
    }

    /// Which engine the sheet reads; its track poll restarts with a new one (a reload under the sheet).
    var engineKey: ObjectIdentifier? { controller.map { ObjectIdentifier($0 as AnyObject) } }

    /// bp-player-sources.tsx BpAudioLane `locked = engine === "html5"`: AVPlayer has no audio delay.
    var delayLocked: Bool { controller?.engineKind == .native }

    /// The engine can change under the sheet (a retry, a switch): the next read is from the new one.
    func use(_ c: (any PlayerEngineControlling)?) {
        controller = c
        refresh()
    }

    func refresh() {
        let now = Self.audio(of: controller)
        if now != tracks { tracks = now }
    }

    /// The row pressed: the track plays, and its language becomes the show's audio language
    /// (bp-ten-foot onAudio). The position is the engine's own and is not touched.
    func select(_ t: MPVPlayerController.Track) {
        controller?.select(track: t, type: "audio")
        controller?.rememberAudio(t)
        refresh()
    }

    func setDelay(_ value: Double) {
        let v: Double = (value * 100).rounded() / 100
        delay = v
        writeDelay(v)
        controller?.setAudioDelay(v)
    }

    func nudge(by step: Double) { setDelay(delay + step) }

    /// The delay as the sheet shows it: "+0.10s", "0.00s".
    var delayLabel: String { String(format: "%@%.2fs", delay > 0 ? "+" : "", delay) }

    /// bp-player-sources.tsx header: the title, then "{n} tracks".
    func headerLine(title: String) -> String {
        let count: String = T("%lld tracks", tracks.count)
        return title.isEmpty ? count : "\(title) · \(count)"
    }
}

/// The home-server quality choice (HomeServerQualityPanel's options and switch).
@MainActor
final class PhoneQualityModel: ObservableObject {
    struct Option: Decodable, Identifiable, Equatable { var id: String; var label: String }
    private struct Options: Decodable { var current: String; var options: [Option] }
    struct Switched: Decodable { var url: String; var headers: [String: String]?; var quality: String; var subtitles: [SeedSubtitle]? }

    @Published private(set) var options: [Option] = []
    @Published private(set) var current = "original"
    @Published private(set) var switching: String?
    @Published private(set) var error: String?
    @Published private(set) var loaded = false

    /// What a press on `id` does: the one playing just closes the sheet; another swaps the stream.
    enum Press: Equatable { case close, switchTo(String), busy }

    func press(_ id: String) -> Press {
        // The pressed row stays enabled while one switch is in flight; a second press does nothing.
        if switching != nil { return .busy }
        return id == current ? .close : .switchTo(id)
    }

    func load(_ h: HomeServerSession) async {
        defer { loaded = true }
        guard let o: Options = try? await HarborEngine.shared.call("homeServers.qualityOptions", [h.connectionId, h.itemId]) else { return }
        options = o.options
        current = o.current
    }

    /// HomeServerQualityPanel select(): the new URL (nil on a failure, which leaves the current stream
    /// playing with upstream's note). The spot and play state go to the server with the switch.
    func switchTo(_ id: String, _ h: HomeServerSession, positionSec: Double, playing: Bool) async -> (url: URL, headers: [String: String], subtitles: [SeedSubtitle])? {
        guard switching == nil else { return nil }
        switching = id
        error = nil
        defer { switching = nil }
        do {
            let r: Switched = try await HarborEngine.shared.call("homeServers.switchQuality",
                [h.connectionId, h.itemId, h.versionId, id, (positionSec * 1000).rounded(), playing, h.playbackSessionId])
            guard let url = URL(string: r.url) else {
                error = T("The current stream is still playing. Original remains available.")
                return nil
            }
            current = r.quality
            return (url, r.headers ?? [:], r.subtitles ?? [])
        } catch {
            self.error = "\(error.localizedDescription) \(T("The current stream is still playing. Original remains available."))"
            return nil
        }
    }
}

/// The stats sheet's rows: what the player is doing (the TV's diagnostics overlay data, laid out for a
/// phone). The source is its host and file extension only, never the full URL (it can carry a debrid
/// or addon token).
enum PhoneStats {
    struct Row: Equatable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    static func source(_ url: URL) -> String {
        let host: String = url.isFileURL ? "file" : (url.host ?? "?")
        let ext: String = url.pathExtension
        return ext.isEmpty ? host : "\(host) .\(ext)"
    }

    static func rows(engine: PlayerEngineKind, url: URL, status: MPVPlayerController.Status,
                     position: Double, duration: Double, buffered: Double, rate: Double) -> [Row] {
        var out: [Row] = [
            Row(label: T("Engine"), value: engine == .native ? "AVPlayer" : "mpv"),
            Row(label: T("Source"), value: source(url)),
            Row(label: T("State"), value: status.error.flatMap { $0.isEmpty ? nil : "\(status.state) — \($0)" } ?? status.state),
        ]
        if duration > 0 {
            out.append(Row(label: T("Position"), value: "\(PlayerClock.fmt(position)) / \(PlayerClock.fmt(duration))"))
            out.append(Row(label: T("Buffered"), value: PlayerClock.fmt(max(buffered, position))))
        }
        if abs(rate - 1) > 0.01 { out.append(Row(label: T("Speed"), value: PhoneSpeedSleep.rateLabel(rate))) }
        if !status.videoParams.isEmpty { out.append(Row(label: T("Video"), value: status.videoParams)) }
        let output: String = [status.vo.isEmpty ? nil : "vo=\(status.vo)", status.hwdec.isEmpty ? nil : "hwdec=\(status.hwdec)"]
            .compactMap { $0 }.joined(separator: " ")
        if !output.isEmpty { out.append(Row(label: T("Output"), value: output)) }
        if !status.drawableSize.isEmpty { out.append(Row(label: T("Drawable"), value: status.drawableSize)) }
        if !status.fps.isEmpty { out.append(Row(label: T("Frame rate"), value: status.fps)) }
        if !status.dropped.isEmpty { out.append(Row(label: T("Dropped frames"), value: status.dropped)) }
        return out
    }

    /// The engine's own log, the last lines (oldest first).
    static func log(_ status: MPVPlayerController.Status, last: Int = 10) -> [String] {
        Array(status.log.suffix(last))
    }
}
