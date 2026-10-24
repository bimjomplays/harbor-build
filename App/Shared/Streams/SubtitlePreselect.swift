import SwiftUI

/// (S4) view.ts PlayerSrc.subtitlePreselect: what the subtitle step chose before playback. `off`
/// is "No subtitles"; otherwise the result's URL, language and title (bp-subtitle-step start():
/// `title: r.title || languageName(r.lang)`). The player hands it to the engine's track plan
/// (TrackMemory.preselect → player.trackPlan), which puts it on in place of the automatic choice
/// and the remembered subtitle, as use-track-autoload's preselect effect does.
struct SubtitlePreselect: Codable, Equatable {
    var off: Bool
    var url: String? = nil
    var lang: String? = nil
    var title: String? = nil
}
