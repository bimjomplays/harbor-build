import SwiftUI

/// The phone player's HUD panels: each one is a compact sheet
/// over the player with .medium / .large detents, the HUD staying hidden behind it. Subtitles, audio,
/// speed & sleep, sources and quality are the session's own panels (`PlayerSession.panel`, the same
/// state the TV's PlayerScreen drives); stats and X-Ray are the phone's alone and live in the view.
/// This file holds the pure rules (which panels a title gets, the speed and sleep lists, the lock);
/// the sheets are in the files beside it.
enum PhonePlayerPanel: String, Identifiable, CaseIterable {
    case subtitles, audio, speed, sources, quality, stats, xray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtitles: return T("Subtitles")
        case .audio: return T("Audio")
        case .speed: return T("Speed & sleep")
        case .sources: return T("Sources")
        case .quality: return T("Quality")
        case .stats: return T("Stats")
        case .xray: return T("X-Ray")
        }
    }

    var icon: String {
        switch self {
        case .subtitles: return "captions.bubble"
        case .audio: return "waveform"
        case .speed: return "speedometer"
        case .sources: return "list.bullet"
        case .quality: return "dial.medium"
        case .stats: return "chart.xyaxis.line"
        case .xray: return "faceid"
        }
    }

    /// The HUD button's and the sheet's accessibility identifiers.
    var buttonID: String { "player-panel-" + rawValue }
    var sheetID: String { "player-sheet-" + rawValue }

    /// The session panel this one is, nil for the phone's own (stats, X-Ray).
    var sessionPanel: PlayerSession.Panel? {
        switch self {
        case .subtitles: return .subtitles
        case .audio: return .audio
        case .speed: return .speed
        case .sources: return .sources
        case .quality: return .homeServerQuality
        case .stats, .xray: return nil
        }
    }

    /// The phone panel a session panel is drawn as; the TV-only ones (Anime4K, the channel guide, the
    /// kid switcher) have no sheet.
    init?(_ p: PlayerSession.Panel) {
        switch p {
        case .subtitles: self = .subtitles
        case .audio: self = .audio
        case .speed: self = .speed
        case .sources: self = .sources
        case .homeServerQuality: self = .quality
        case .anime4k, .channels, .kidsSources: return nil
        }
    }

    // MARK: which panels a title gets

    /// What a Sources press does: the switcher sheet swaps the stream in place; where it can't (a
    /// home-server copy, a kid profile) the picker reopens at this spot; with neither, no button.
    enum SourcesRoute: Equatable { case sheet, reopen, none }

    struct Facts: Equatable {
        var isLive = false
        var hasHomeServer = false
        var sources: SourcesRoute = .none
        /// settings.xrayEnabled, for a title with something to read the cast of (not a kid profile).
        var xray = false
        var isKid = false
    }

    static func sourcesRoute(canSwitchInPlace: Bool, canReopen: Bool) -> SourcesRoute {
        canSwitchInPlace ? .sheet : (canReopen ? .reopen : .none)
    }

    /// The HUD's panel buttons, in order (bp-player-rail.tsx's: Subtitles, Audio, Speed & sleep, Sources,
    /// the home-server quality, then the phone's Stats and X-Ray).
    static func shown(_ f: Facts) -> [PhonePlayerPanel] {
        var out: [PhonePlayerPanel] = [.subtitles, .audio, .speed]
        if f.sources != .none { out.append(.sources) }
        if !f.isLive, f.hasHomeServer { out.append(.quality) }
        if !f.isKid { out.append(.stats) }
        if f.xray, !f.isKid { out.append(.xray) }
        return out
    }
}

/// Lock controls: a lock button in the HUD makes the player ignore every touch until it is unlocked,
/// so a pocket or a child's hand can't seek or pause. A touch on the locked player brings up a lone
/// Unlock button for a few seconds. No kids-specific limits (the lock is the same for every profile).
struct PhonePlayerLock: Equatable {
    private(set) var locked = false
    /// The Unlock button is on screen.
    private(set) var hintShown = false
    /// How long the Unlock button stays after a touch.
    static let hintFor: Double = 3

    /// The stage, the HUD and the panels take touches.
    var passesTouches: Bool { !locked }

    mutating func lock() {
        locked = true
        hintShown = false
    }

    /// A touch on the locked player: only the Unlock button comes up.
    mutating func touched() {
        if locked { hintShown = true }
    }

    mutating func hintExpired() { hintShown = false }

    mutating func unlock() {
        locked = false
        hintShown = false
    }
}

/// Speed & sleep (speed-menu.tsx): the lists, their labels and the HUD button's face.
enum PhoneSpeedSleep {
    static let curatedSpeeds: [Double] = [0.75, 1, 1.25, 1.5, 2]
    static let curatedSleepMinutes: [Int] = [30, 60]

    /// The curated speeds plus the viewer's own (settings.customPlaybackSpeeds), sorted; a synced
    /// speed outside what both engines play (0 would stall AVPlayer) is skipped.
    static func speeds(custom: [Double]?) -> [Double] {
        var all = curatedSpeeds
        for s in custom ?? [] where s.isFinite && s >= 0.25 && s <= 4 && !all.contains(where: { abs($0 - s) < 0.001 }) { all.append(s) }
        return all.sorted()
    }

    /// 30 and 60 minutes plus settings.customSleepMinutes, sorted.
    static func sleepMinutes(custom: [Double]?) -> [Int] {
        var all = curatedSleepMinutes
        for raw in custom ?? [] where raw.isFinite {
            let m = Int(raw.rounded())
            if m >= 1, !all.contains(m) { all.append(m) }
        }
        return all.sorted()
    }

    /// "Normal" at 1×, else "1.5×".
    static func rateLabel(_ v: Double) -> String {
        abs(v - 1) < 0.001 ? T("Normal") : String(format: "%g×", v)
    }

    static func isRate(_ v: Double, _ rate: Double) -> Bool { abs(v - rate) < 0.01 }

    struct SleepRow: Identifiable, Equatable {
        var label: String
        var mode: SleepTimer.Mode
        var icon: String
        var isMinutes: Bool
        var id: String { label }

        static func == (a: SleepRow, b: SleepRow) -> Bool { a.label == b.label && a.isMinutes == b.isMinutes }
    }

    /// speed-menu.tsx sleepList: the minute rows, then "End of episode" and "End of next episode".
    @MainActor static func sleepRows(minutes: [Int]) -> [SleepRow] {
        minutes.map { SleepRow(label: SleepTimer.minuteLabel($0), mode: .minutes(total: $0, firesAt: Date()), icon: "clock", isMinutes: true) }
            + [SleepRow(label: T("End of episode"), mode: .endEpisode, icon: "moon", isMinutes: false),
               SleepRow(label: T("End of next episode"), mode: .endNextEpisode(remaining: 2), icon: "moon.zzz", isMinutes: false)]
    }

    /// speed-menu.tsx isSel: the same minute total, or the same episode kind.
    static func isSelected(_ current: SleepTimer.Mode, _ row: SleepTimer.Mode) -> Bool {
        switch (current, row) {
        case (.minutes(let a, _), .minutes(let b, _)): return a == b
        case (.endEpisode, .endEpisode): return true
        case (.endNextEpisode, .endNextEpisode): return true
        default: return false
        }
    }

    /// The HUD button's face: the sleep countdown while a timer is armed, else a changed rate; nil
    /// leaves the speedometer icon alone.
    static func face(rate: Double, isLive: Bool, sleepFace: String?) -> String? {
        if let sleepFace { return sleepFace }
        if !isLive, abs(rate - 1) > 0.01 { return rateLabel(rate) }
        return nil
    }
}
