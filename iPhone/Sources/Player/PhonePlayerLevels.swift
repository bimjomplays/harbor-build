import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// The phone's own volume, as the player's volume capsule and the right-half swipe move it. It reads
/// the audio session's output volume (and follows the side buttons), and writes through a system
/// volume slider kept out of sight in the player (PhoneVolumeHost), which also keeps the system's own
/// volume HUD from covering the picture while the player is up.
@MainActor
final class PhoneVolume: ObservableObject {
    @Published private(set) var level: Double
    private var observation: NSKeyValueObservation?
    fileprivate weak var slider: UISlider?

    init(start: Double? = nil) {
        level = start ?? Double(AVAudioSession.sharedInstance().outputVolume)
        // Under a fixture start the level is the test's, not the simulator's.
        guard start == nil else { return }
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let v = Double(session.outputVolume)
            Task { @MainActor in
                guard let self, abs(self.level - v) > 0.004 else { return }
                self.level = v
            }
        }
    }

    func set(_ value: Double) {
        let v: Double = min(1, max(0, value))
        level = v
        slider?.setValue(Float(v), animated: false)
        slider?.sendActions(for: .valueChanged)
    }
}

/// The system volume view, all but invisible: it has to be on screen (not hidden) for the system to
/// keep its own volume HUD away and for its slider to move the volume.
struct PhoneVolumeHost: UIViewRepresentable {
    let volume: PhoneVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        v.alpha = 0.011
        v.isUserInteractionEnabled = false
        v.showsRouteButton = false
        return v
    }

    func updateUIView(_ v: MPVolumeView, context: Context) {
        if volume.slider == nil { volume.slider = v.subviews.compactMap { $0 as? UISlider }.first }
    }
}

/// The screen's brightness, as the left-half swipe moves it. The level the phone had when the player
/// first changed it comes back when the player goes or the app leaves the screen.
@MainActor
final class PhoneBrightness: ObservableObject {
    @Published private(set) var level: Double
    private var saved: CGFloat?
    private let fixture: Bool

    init(start: Double? = nil) {
        fixture = start != nil
        level = start ?? 0.5
        if start == nil, let s = Self.screen { level = Double(s.brightness) }
    }

    private static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }

    /// A swipe starts: the level is read again (Control Center may have moved it).
    func begin() {
        guard !fixture, let s = Self.screen else { return }
        if saved == nil { saved = s.brightness }
        level = Double(s.brightness)
    }

    func set(_ value: Double) {
        let v: Double = min(1, max(0, value))
        level = v
        guard !fixture else { return }
        Self.screen?.brightness = CGFloat(v)
    }

    /// The phone's own level again.
    func restore() {
        guard let s = saved else { return }
        saved = nil
        Self.screen?.brightness = s
    }
}
