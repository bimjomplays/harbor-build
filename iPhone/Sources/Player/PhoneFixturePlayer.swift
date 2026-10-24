import SwiftUI
import UIKit

/// The engine the player draws under UI-test fixtures (PlayerFixtures.standInEngine): the fixture
/// links point nowhere, so mpv and AVPlayer could only fail on them. It plays a silent two-hour
/// "file" the way a real engine reports one: loading, then playing from 0, and the start seek lands
/// a moment later (the window in which an early save would have written 0:00 over the saved spot).
/// A label (`player-fixture`) shows where it is, the audio and subtitle track on, the speed and
/// the delays, the subtitles the picker handed over and the first progress save of the launch, for
/// PlayerTests and the panel tests.
struct PhoneFixturePlayer: UIViewControllerRepresentable {
    let kind: PlayerEngineKind
    let startAt: Double
    let subtitles: String?
    let onStatus: (MPVPlayerController.Status) -> Void
    let onEnded: () -> Void
    let onReady: (PhoneFixtureEngine) -> Void
    var onPictureInPicture: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> PhoneFixtureEngine {
        let c = PhoneFixtureEngine(kind: kind)
        c.startAtSeconds = startAt
        c.subtitles = subtitles
        c.onStatus = onStatus
        c.onEnded = onEnded
        c.onPictureInPicture = onPictureInPicture
        // As the real engine views do: delivered a main-queue turn after creation.
        DispatchQueue.main.async { onReady(c) }
        return c
    }

    func updateUIViewController(_ c: PhoneFixtureEngine, context: Context) {}

    static func dismantleUIViewController(_ c: PhoneFixtureEngine, coordinator: ()) {
        c.stop()
    }
}

final class PhoneFixtureEngine: UIViewController, PlayerEngineControlling {
    static let duration: Double = 7200
    /// When the start seek lands after the open (a real engine's first frames come first).
    static let seekLandsAfter: TimeInterval = 1.5

    let engineKind: PlayerEngineKind
    var startAtSeconds: Double = 0
    var subtitles: String?
    var onStatus: ((MPVPlayerController.Status) -> Void)?
    var onEnded: (() -> Void)?
    /// The stand-in's PiP: a flag the player screen's placard follows (AVKit's window needs a device).
    var onPictureInPicture: ((Bool) -> Void)?
    private var pip = false

    private var position: Double = 0
    private var paused = false
    private var muted = false
    private var rate: Double = 1
    private var playing = false
    private var landed = false
    private var ended = false
    private var fill = false
    private var audioDelay: Double = 0
    private var subDelay: Double = 0
    /// Two audio and two subtitle tracks, as a film's file has: English (5.1) plays, subtitles are off.
    private var trackList: [MPVPlayerController.Track] = [
        MPVPlayerController.Track(id: 1, type: "audio", lang: "eng", title: "English", codec: "ac3", selected: true, isDefault: true, channels: "5.1"),
        MPVPlayerController.Track(id: 2, type: "audio", lang: "jpn", title: "Japanese", codec: "aac", selected: false, channels: "2.0"),
        MPVPlayerController.Track(id: 3, type: "sub", lang: "eng", title: "English", codec: "subrip", selected: false, isDefault: true),
        MPVPlayerController.Track(id: 4, type: "sub", lang: "spa", title: "Spanish", codec: "subrip", selected: false),
    ]
    private let opened = Date()
    private var lastStep = Date()
    private var timer: Timer?
    private let label = UILabel()

    init(kind: PlayerEngineKind) {
        engineKind = kind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "player-fixture"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 70),
        ])
        // Reported a turn later: not from inside the SwiftUI update that built the view.
        DispatchQueue.main.async { [weak self] in self?.report("loading") }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.step() }
        refreshLabel()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    private func report(_ state: String) {
        var s = MPVPlayerController.Status()
        s.state = state
        onStatus?(s)
    }

    private func step() {
        let now = Date()
        let dt: Double = now.timeIntervalSince(lastStep)
        lastStep = now
        let age: TimeInterval = now.timeIntervalSince(opened)
        if !playing, age >= 0.4 {
            playing = true
            report("playing")
        }
        if !landed, age >= Self.seekLandsAfter {
            landed = true
            if startAtSeconds > 0 { position = min(Self.duration, startAtSeconds) }
        }
        if playing, !paused, !ended { position = min(Self.duration, position + dt * rate) }
        if position >= Self.duration, !ended {
            ended = true
            report("ended")
            onEnded?()
        }
        refreshLabel()
    }

    private func refreshLabel() {
        var lines: [String] = ["fixture \(PlayerClock.fmt(position)) / \(PlayerClock.fmt(Self.duration))"]
        lines.append(fill ? "fill" : "fit")
        let audio: String = trackList.first { $0.type == "audio" && $0.selected }.map { String($0.id) } ?? "off"
        let sub: String = trackList.first { $0.type == "sub" && $0.selected }.map { String($0.id) } ?? "off"
        lines.append("audio \(audio)")
        lines.append("sub \(sub)")
        lines.append("rate " + String(format: "%g", rate))
        lines.append("delay " + String(format: "%.1f/%.1f", audioDelay, subDelay))
        if let subtitles { lines.append(subtitles) }
        lines.append("saved " + (PlayerFixtures.firstSave.map { String(Int($0.rounded())) } ?? "none"))
        let text: String = lines.joined(separator: " · ")
        label.text = text
        label.accessibilityLabel = text
    }

    // MARK: PlayerEngineControlling

    func togglePause() { paused.toggle() }
    func setPaused(_ paused: Bool) { self.paused = paused }

    func seek(_ seconds: Double) { seek(to: position + seconds) }

    func seek(to seconds: Double) {
        // A seek of the viewer's before the start seek landed replaces it.
        landed = true
        position = max(0, min(Self.duration, seconds))
        refreshLabel()
    }

    func snapshot() -> (position: Double, duration: Double, paused: Bool) {
        (position, playing ? Self.duration : 0, paused)
    }

    func tracks() -> [MPVPlayerController.Track] { trackList }

    /// One track of a kind plays at a time; nil turns the subtitles off.
    func select(track: MPVPlayerController.Track?, type: String) {
        for i in trackList.indices where trackList[i].type == type { trackList[i].selected = trackList[i].id == track?.id }
        refreshLabel()
    }

    func setSecondarySub(_ track: MPVPlayerController.Track?) {}

    func setAudioDelay(_ seconds: Double) {
        audioDelay = seconds
        refreshLabel()
    }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func isMuted() -> Bool { muted }
    func setRate(_ rate: Double) {
        self.rate = rate
        refreshLabel()
    }
    func bufferedSec() -> Double { min(Self.duration, position + 30) }
    func streamFilename() -> String? { nil }
    func refreshSubtitleStyle() {}
    func setSubDelay(_ seconds: Double) {
        subDelay = seconds
        refreshLabel()
    }

    func currentSubDelay() -> Double { subDelay }
    var trackMemory: TrackMemory? { nil }
    func setShaders(_ paths: [String]) {}
    func videoWidth() -> Int { 1920 }
    func chapters() -> [PlayerChapter] { [] }
    func addSubtitle(file: URL, title: String, lang: String) {}
    func addSeedSubtitle(file: URL, title: String, lang: String) {}
    var subPicks: Int { 0 }
    var supportsPictureInPicture: Bool { engineKind == .native }
    var isPictureInPictureActive: Bool { pip }
    func startPictureInPicture() {
        guard supportsPictureInPicture, !pip else { return }
        pip = true
        onPictureInPicture?(true)
    }
    func stopPictureInPicture() {
        guard pip else { return }
        pip = false
        onPictureInPicture?(false)
    }
    func grabFrame(fullQuality: Bool, done: @escaping (Data?) -> Void) { done(nil) }

    func setPictureFill(_ fill: Bool) {
        self.fill = fill
        refreshLabel()
    }
}
