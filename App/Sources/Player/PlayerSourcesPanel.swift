import SwiftUI

// bp-player-sources.tsx BpPlayerSources: the in-player source switcher.

/// bp-player-sources.tsx BpPlayerSources: `<BpStreams {...props} mode="switch" />`, the title's
/// streams as a card over the running film. It is the picker itself in its switch mode
/// (PlayPickerView `switching`): the same search, chips, filters, rows and resolve path (P2P consent,
/// the debrid retries, "Debrid is down"), with the stream playing now first and marked. A pick
/// hands the resolved stream to the player (PlayerScreen.switchSource), which swaps it in place at
/// the current position; the panel closes then (bp-ten-foot SourcesPanel closes when the playing
/// URL moves) and stays open on a failed resolve, with the reason.
struct PlayerSourcesPanel: View {
    let meta: Meta
    /// The PlayEpisode the search runs with (the picker's own, else one built from the context).
    let episode: AnyJSON?
    let current: Current
    let onPicked: (ScoredStream?, StreamsModel.Resolved) -> Void
    let onClose: () -> Void

    var body: some View {
        PlayPickerView(meta: meta, episode: episode, onPlay: onPicked, switching: current, onClose: onClose)
    }

    /// What plays now, for switcher-row.tsx isCurrentStream (the type lives in App/Shared with the
    /// picker's model).
    typealias Current = PlayingSource
}
