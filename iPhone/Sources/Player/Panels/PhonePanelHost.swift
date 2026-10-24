import SwiftUI

/// What the player's panel sheet shows for one panel: the sheet's detents (.medium to peek
/// while the film stays visible above, .large to read), its drag indicator and the presence mark the UI
/// tests and the rotation lock read. Dark like the player, whatever the app's mode.
struct PhonePanelSheet: View {
    let panel: PhonePlayerPanel
    @ObservedObject var session: PlayerSession
    /// What plays now, for the Sources sheet's "Now playing" row.
    let source: PlayingSource
    let onClose: () -> Void

    var body: some View {
        content
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentedCover("player-panel")
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .subtitles: PhoneSubtitlesSheet(session: session, onClose: onClose)
        case .audio: PhoneAudioSheet(session: session, onClose: onClose)
        case .speed: PhoneSpeedSheet(session: session, onClose: onClose)
        case .quality:
            if let home = session.context?.homeServer { PhoneQualitySheet(session: session, home: home, onClose: onClose) }
        case .stats: PhoneStatsSheet(session: session, onClose: onClose)
        case .xray: PhoneXRaySheet(meta: session.context?.meta, onClose: onClose)
        case .sources:
            // The same list as the play picker, in switching mode: a pick swaps the stream in place at the
            // spot (PlayerSession.switchSource), and the sheet closes with it.
            if let meta = session.context?.meta {
                PhonePlayPicker(meta: meta, video: session.pickEpisode ?? session.context.flatMap { session.kidsEpisode($0) },
                                dismiss: onClose, switching: source,
                                onPicked: { stream, resolved in session.switchSource(stream, resolved) })
            }
        }
    }
}
