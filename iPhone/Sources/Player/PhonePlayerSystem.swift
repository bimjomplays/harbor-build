import AVFoundation
import AVKit
import SwiftUI

/// The phone player's seams with the system: the audio session
/// that lets sound go on in the background, what the HUD's Picture in Picture and AirPlay buttons do
/// on each engine, and the words for the tab bar's mini state. Pure helpers, so the unit tests reach
/// them; PhonePlayerView only forwards.
enum PhonePlayerSystem {
    /// Background audio needs the `.playback` category active (and UIBackgroundModes audio, project.yml).
    /// The engines set it too; doing it when the screen appears means the session is live before the
    /// first frame, so a swipe home right after Play keeps going.
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    /// What the HUD's Picture in Picture button does.
    enum PiPAction: Equatable {
        /// AVPlayer's own window: start it.
        case start
        /// Already floating: bring the picture back.
        case stop
        /// mpv draws into a Metal layer AVKit cannot float: offer the AVPlayer engine instead.
        case offerNative
        /// This device has no Picture in Picture.
        case hidden
    }

    static func pipAction(engine: PlayerEngineKind, supported: Bool, active: Bool) -> PiPAction {
        switch engine {
        case .native:
            if active { return .stop }
            return supported ? .start : .hidden
        case .mpv:
            return .offerNative
        }
    }

    /// What the HUD's AirPlay button does: the system route picker on AVPlayer, which hands the stream
    /// to the route; mpv has no route to hand, so it offers the AVPlayer engine.
    enum AirPlayAction: Equatable {
        case picker
        case offerNative
    }

    static func airPlayAction(engine: PlayerEngineKind) -> AirPlayAction {
        engine == .native ? .picker : .offerNative
    }

    /// The sentence under the engine-switch offer, naming what the button was for.
    static func offerMessage(for feature: Feature) -> String {
        switch feature {
        case .pictureInPicture:
            return T("Picture in Picture works on the AVPlayer engine only. This video plays in mpv. Switching carries on from here.")
        case .airPlay:
            return T("AirPlay works on the AVPlayer engine only. This video plays in mpv. Switching carries on from here.")
        }
    }

    static func offerButton(for feature: Feature) -> String {
        switch feature {
        case .pictureInPicture: return T("Switch to the AVPlayer engine")
        case .airPlay: return T("Switch to AirPlay-capable engine")
        }
    }

    enum Feature: Equatable {
        case pictureInPicture, airPlay
    }
}

/// The player that is floating in Picture in Picture, for the tab bar's accessory. Set by the player
/// screen while its picture is in the window, cleared when it comes back or closes.
@MainActor
final class PhoneMiniState: ObservableObject {
    static let shared = PhoneMiniState()

    struct Live: Equatable {
        let title: String
        let subtitle: String?
    }

    @Published private(set) var live: Live?
    /// Brings the floating picture back to the player (the accessory's tap).
    private(set) var bringBack: (() -> Void)?
    /// Stops and saves the floating player, for another video starting while it floats (PhonePlay.handOff).
    private(set) var end: (() -> Void)?

    func set(_ live: Live, bringBack: @escaping () -> Void, end: @escaping () -> Void = {}) {
        self.live = live
        self.bringBack = bringBack
        self.end = end
    }

    func clear() {
        live = nil
        bringBack = nil
        end = nil
    }
}

/// What the tab bar's bottom accessory shows: the live Picture in Picture state while a picture is
/// floating, else Resume for the newest Continue Watching title, else nothing.
enum PhoneAccessory: Equatable {
    case mini(String)
    case resume(String)

    static func choose(resume: ContinueItem?, mini: PhoneMiniState.Live?) -> PhoneAccessory? {
        if let mini { return .mini(miniText(mini)) }
        if let resume { return .resume(PhoneResume.accessoryText(resume)) }
        return nil
    }

    /// "Playing Severance in Picture in Picture · S2E3".
    static func miniText(_ live: PhoneMiniState.Live) -> String {
        let lead = T("Playing %@ in Picture in Picture", live.title)
        guard let sub = live.subtitle, !sub.isEmpty else { return lead }
        return "\(lead) · \(sub)"
    }
}

/// The system route sheet behind the HUD's own AirPlay button: an AVRoutePickerView sits out of
/// sight (PhoneAirPlayAnchor) and the button presses its inner button, so the HUD's orb looks and
/// behaves like the others while AVKit still lists the routes and hands the stream over.
@MainActor
final class PhoneAirPlayRoutes: ObservableObject {
    fileprivate weak var picker: AVRoutePickerView?

    func present() {
        guard let button = picker?.subviews.compactMap({ $0 as? UIButton }).first else { return }
        button.sendActions(for: .touchUpInside)
    }
}

struct PhoneAirPlayAnchor: UIViewRepresentable {
    let routes: PhoneAirPlayRoutes

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.alpha = 0.011
        routes.picker = v
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        routes.picker = uiView
    }
}
