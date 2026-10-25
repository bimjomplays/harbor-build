import Foundation

/// The gear menu's words and lists (Volume Boost, Playback Speed, the audio track, the subtitle,
/// Advanced Options), with no view in them so the unit tests reach them. PhonePlayerGearMenu builds
/// the menu from these.
enum PhonePlayerMenuModel {
    // MARK: volume boost

    /// mpv plays louder than 100 %: Disabled, then +50 % … +300 %.
    static let boostSteps: [Int] = [0, 50, 100, 150, 200, 250, 300]

    /// "Disabled", else "+150%".
    static func boostLabel(_ percent: Int) -> String {
        percent <= 0 ? T("Disabled") : "+\(percent)%"
    }

    // MARK: playback speed

    /// The speeds the menu lists: the quarter steps from 0.25× to 2× plus the viewer's own
    /// (settings.customPlaybackSpeeds), sorted. A synced speed outside what both engines play is skipped.
    static func speeds(custom: [Double]?) -> [Double] {
        var all: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        for s in custom ?? [] where s.isFinite && s >= 0.25 && s <= 4 && !all.contains(where: { abs($0 - s) < 0.001 }) { all.append(s) }
        return all.sorted()
    }

    /// "Normal" at 1x, else "1.25x".
    static func speedLabel(_ v: Double) -> String {
        abs(v - 1) < 0.001 ? T("Normal") : String(format: "%gx", v)
    }

    // MARK: tracks

    /// mpv's codec names as a viewer reads them.
    static func codecName(_ codec: String?) -> String? {
        guard let raw = codec?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let known: [String: String] = [
            "eac3": "E-AC3", "ac3": "AC3", "aac": "AAC", "dts": "DTS", "dca": "DTS", "truehd": "TrueHD", "opus": "Opus",
            "flac": "FLAC", "mp3": "MP3", "vorbis": "Vorbis", "alac": "ALAC", "mp2": "MP2",
            "pcm_s16le": "PCM", "pcm_s24le": "PCM", "pcm_s32le": "PCM",
            "subrip": "SRT", "srt": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT", "mov_text": "Text",
            "hdmv_pgs_subtitle": "PGS", "pgs": "PGS", "dvd_subtitle": "VobSub", "dvb_subtitle": "DVB",
        ]
        return known[raw] ?? raw.uppercased()
    }

    /// mpv's demux-channels as a count: "5.1(side)" → "5.1", "stereo" → "2.0", "mono" → "1.0".
    static func channelsName(_ channels: String?) -> String? {
        guard var c = channels?.trimmingCharacters(in: .whitespaces).lowercased(), !c.isEmpty else { return nil }
        if let cut = c.firstIndex(of: "(") { c = String(c[..<cut]) }
        switch c {
        case "mono": return "1.0"
        case "stereo": return "2.0"
        default: return c.isEmpty ? nil : c
        }
    }

    private static func language(_ t: MPVPlayerController.Track) -> String? {
        guard let l = t.lang?.trimmingCharacters(in: .whitespaces), !l.isEmpty, l.lowercased() != "und" else { return nil }
        return TrackLanguage.englishName(l) ?? l.uppercased()
    }

    /// The track's own name, when it says more than its language does.
    private static func ownTitle(_ t: MPVPlayerController.Track, language: String?) -> String? {
        guard let s = t.title?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != t.lang, s != language else { return nil }
        return s
    }

    /// "English - E-AC3 5.1": the audio track as the gear menu's row and the list's header name it.
    static func audioHead(_ t: MPVPlayerController.Track) -> String {
        let tech: String = [codecName(t.codec), channelsName(t.channels)].compactMap { $0 }.joined(separator: " ")
        let lang: String? = language(t)
        switch (lang, tech.isEmpty) {
        case (let l?, false): return "\(l) - \(tech)"
        case (let l?, true): return l
        case (nil, false): return ownTitle(t, language: nil) ?? tech
        case (nil, true): return ownTitle(t, language: nil) ?? T("Audio %lld", t.id)
        }
    }

    /// "English - E-AC3 5.1 (Default, Director's commentary)": a row in the audio list.
    static func audioRow(_ t: MPVPlayerController.Track) -> String {
        let head: String = audioHead(t)
        var extra: [String] = []
        if t.isDefault { extra.append(T("Default")) }
        if let own = ownTitle(t, language: language(t)), !head.contains(own) { extra.append(own) }
        return extra.isEmpty ? head : "\(head) (\(extra.joined(separator: ", ")))"
    }

    /// "English": the subtitle as the gear menu's row names it.
    static func subtitleHead(_ t: MPVPlayerController.Track) -> String {
        language(t) ?? ownTitle(t, language: nil) ?? T("Subtitle %lld", t.id)
    }

    /// "English (SDH, Forced, Default)": a row in the subtitle list.
    static func subtitleRow(_ t: MPVPlayerController.Track) -> String {
        let head: String = subtitleHead(t)
        var extra: [String] = []
        if let own = ownTitle(t, language: language(t)), own != head { extra.append(own) }
        if t.hearingImpaired, !extra.contains(where: { $0.contains("SDH") }) { extra.append("SDH") }
        if t.forced, !extra.contains(where: { $0.localizedCaseInsensitiveContains(T("Forced")) }) { extra.append(T("Forced")) }
        if t.isDefault { extra.append(T("Default")) }
        if t.external, !t.seeded { extra.append(T("Added")) }
        return extra.isEmpty ? head : "\(head) (\(extra.joined(separator: ", ")))"
    }

    /// The audio row's title: the track that is on, else "Audio".
    static func audioTitle(_ tracks: [MPVPlayerController.Track]) -> String {
        tracks.first { $0.type == "audio" && $0.selected }.map(audioHead) ?? T("Audio")
    }

    /// The subtitle row's title: the subtitle that is on, else "None".
    static func subtitleTitle(_ tracks: [MPVPlayerController.Track]) -> String {
        tracks.first { $0.type == "sub" && $0.selected }.map(subtitleHead) ?? T("None")
    }
}
