import UIKit
import SwiftUI
import AVFoundation
import AVKit
import CoreMedia


/// PlayerScreen's native surface, the counterpart of MPVPlayerView.
struct NativePlayerView: UIViewControllerRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    var startAt: Double = 0
    var isLive: Bool = false
    var preferredAudio: [String] = []
    var preferredSubs: [String] = []
    /// Per-show track memory key (TrackMemory.swift); nil remembers nothing.
    var trackMemory: TrackMemory? = nil
    /// view.ts PlayerSrc.subtitles: the stream's own subtitles, added unselected once it opens.
    var seedSubtitles: [SeedSubtitle] = []
    let onStatus: (MPVPlayerController.Status) -> Void
    var onEnded: (() -> Void)? = nil
    var onUnsupported: ((String) -> Void)? = nil
    var onReady: ((NativePlayerController) -> Void)? = nil
    /// Picture in Picture started (true) or is ending (false).
    var onPictureInPicture: ((Bool) -> Void)? = nil
    /// The PiP window's restore button was pressed (the player screen must come back to the front).
    var onPictureInPictureRestore: (() -> Void)? = nil
    /// The viewer closed the PiP window.
    var onPictureInPictureClosed: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> NativePlayerController {
        let c = NativePlayerController()
        c.url = url
        c.headers = headers
        c.startAtSeconds = startAt
        c.isLive = isLive
        c.preferredAudio = preferredAudio
        c.preferredSubs = preferredSubs
        c.trackMemory = trackMemory
        c.seedSubtitles = seedSubtitles
        c.onStatus = onStatus
        c.onEnded = onEnded
        c.onUnsupported = onUnsupported
        c.onPictureInPicture = onPictureInPicture
        c.onPictureInPictureRestore = onPictureInPictureRestore
        c.onPictureInPictureClosed = onPictureInPictureClosed
        DispatchQueue.main.async { onReady?(c) }
        return c
    }

    func updateUIViewController(_ c: NativePlayerController, context: Context) {}

    /// The view left the hierarchy for good (a cover over it does not count).
    static func dismantleUIViewController(_ c: NativePlayerController, coordinator: ()) {
        c.stop()
    }
}
