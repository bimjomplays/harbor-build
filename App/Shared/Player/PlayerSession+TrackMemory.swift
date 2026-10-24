import Foundation

extension PlayerSession {
    /// The memory key for this playback: a title's own stream (not a live channel).
    var trackMemory: TrackMemory? {
        guard let context, !isLive else { return nil }
        return TrackMemory(metaId: context.meta.id, season: context.season, episode: context.episode,
                           genres: context.meta.genres ?? [],
                           // After an in-place switch the original release's filename no longer applies;
                           // the source switcher's pick names its own (subtitleStreamKey
                           // over activeMediaSrc.streamRef), a home-server quality keeps the release's,
                           // the kid switcher none.
                           filename: switchedInPlace ? switchedFilename : streamHints?.filename,
                           // (S4) The step chose for the stream it opened; a stream swapped in place
                           // gets the plan's own choice.
                           preselect: switchedInPlace ? nil : subtitlePreselect)
    }
}
