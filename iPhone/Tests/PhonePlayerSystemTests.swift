import MediaPlayer
import XCTest
@testable import HarborPhone

/// what the phone player tells the system. The Now Playing dictionary (Lock Screen, Control
/// Center, Dynamic Island), the tab bar accessory's words and choice, what the HUD's Picture in
/// Picture and AirPlay buttons do on each engine, and the torrent's background note. PiP, the Lock
/// Screen and the route sheet themselves need a device.
@MainActor
final class PhonePlayerSystemTests: XCTestCase {
    // MARK: Now Playing

    func testNowPlayingInfoForAnEpisodePlaying() {
        let info = VideoNowPlaying.info(playing: true, title: "Severance", subtitle: "S2E4 · Woe's Hollow", durationSec: 3_000,
                                        positionSec: 125, rate: 1, isLive: false)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Severance")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "S2E4 · Woe's Hollow")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 3_000)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 125)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.video.rawValue)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)
    }

    /// Paused is rate 0: it is what stops the clock the Lock Screen draws between updates.
    func testNowPlayingRateIsZeroWhilePausedAndKeepsTheSpeed() {
        let paused = VideoNowPlaying.info(playing: false, title: "Dune", subtitle: nil, durationSec: 100, positionSec: 10, rate: 1.5, isLive: false)
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        let fast = VideoNowPlaying.info(playing: true, title: "Dune", subtitle: nil, durationSec: 100, positionSec: 10, rate: 1.5, isLive: false)
        XCTAssertEqual(fast[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
    }

    func testNowPlayingLeavesOutWhatIsNotKnown() {
        let info = VideoNowPlaying.info(playing: true, title: "Dune", subtitle: "", durationSec: 0, positionSec: nil, rate: 1, isLive: false)
        XCTAssertNil(info[MPMediaItemPropertyArtist], "an empty episode line is not an artist")
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
    }

    /// A channel has neither a length nor a position, and says it is live.
    func testNowPlayingForAChannelIsLive() {
        let info = VideoNowPlaying.info(playing: true, title: "News", subtitle: nil, durationSec: 3_600, positionSec: 40, rate: 1, isLive: true)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
    }

    // MARK: The tab bar accessory

    private func item(_ name: String = "Severance", season: Int? = 2, episode: Int? = 3, durationMin: Double = 0, leftMin: Double = 0) -> ContinueItem {
        var i = ContinueItem(id: "tt1", type: season == nil ? "movie" : "series", name: name, poster: nil, background: nil, logo: nil,
                             season: season, episode: episode, progress: 0.5, lastWatched: nil)
        i.durationMs = durationMin * 60_000
        i.timeOffsetMs = (durationMin - leftMin) * 60_000
        return i
    }

    func testResumeTextNamesTheEpisodeAndTimeLeft() {
        XCTAssertEqual(PhoneResume.accessoryText(item(durationMin: 50, leftMin: 34)), "Resume Severance · S2E3 · 34 min left")
    }

    func testResumeTextForAFilmAndForAnUnknownLength() {
        XCTAssertEqual(PhoneResume.accessoryText(item("Dune", season: nil, episode: nil, durationMin: 160, leftMin: 61)), "Resume Dune · 61 min left")
        XCTAssertEqual(PhoneResume.accessoryText(item()), "Resume Severance · S2E3")
        XCTAssertEqual(PhoneResume.accessoryText(item("Dune", season: nil, episode: nil)), "Resume Dune")
    }

    func testResumeTextRoundsTheMinutesLeftUp() {
        var i = item(durationMin: 50, leftMin: 0)
        i.timeOffsetMs = 50 * 60_000 - 20_000   // 20 s left
        XCTAssertEqual(PhoneResume.minutesLeft(i), 1)
        i.timeOffsetMs = 50 * 60_000 - 61_000   // 61 s left
        XCTAssertEqual(PhoneResume.minutesLeft(i), 2)
    }

    func testMiniTextNamesTheTitleAndEpisode() {
        XCTAssertEqual(PhoneAccessory.miniText(.init(title: "Severance", subtitle: "S2E3")), "Playing Severance in Picture in Picture · S2E3")
        XCTAssertEqual(PhoneAccessory.miniText(.init(title: "Dune", subtitle: nil)), "Playing Dune in Picture in Picture")
        XCTAssertEqual(PhoneAccessory.miniText(.init(title: "Dune", subtitle: "")), "Playing Dune in Picture in Picture")
    }

    func testAccessoryChoice() {
        let resume = item(durationMin: 50, leftMin: 34)
        let mini = PhoneMiniState.Live(title: "Severance", subtitle: "S2E3")
        XCTAssertNil(PhoneAccessory.choose(resume: nil, mini: nil), "nothing to resume, nothing floating: no strip")
        XCTAssertEqual(PhoneAccessory.choose(resume: resume, mini: nil), .resume("Resume Severance · S2E3 · 34 min left"))
        XCTAssertEqual(PhoneAccessory.choose(resume: nil, mini: mini), .mini("Playing Severance in Picture in Picture · S2E3"))
        XCTAssertEqual(PhoneAccessory.choose(resume: resume, mini: mini), .mini("Playing Severance in Picture in Picture · S2E3"),
                       "a floating picture comes before Resume")
    }

    func testMiniStateSetAndClear() {
        let state = PhoneMiniState()
        var brought = 0
        state.set(.init(title: "Dune", subtitle: nil), bringBack: { brought += 1 })
        XCTAssertEqual(state.live?.title, "Dune")
        state.bringBack?()
        XCTAssertEqual(brought, 1)
        state.clear()
        XCTAssertNil(state.live)
        XCTAssertNil(state.bringBack)
        XCTAssertNil(state.end)
    }

    func testMiniStateEndStopsTheFloatingPlayer() {
        let state = PhoneMiniState()
        var ended = 0
        state.set(.init(title: "Dune", subtitle: nil), bringBack: {}, end: { ended += 1 })
        state.end?()
        XCTAssertEqual(ended, 1)
        state.clear()
        state.end?()
        XCTAssertEqual(ended, 1, "a cleared state has nothing left to end")
    }

    // MARK: Picture in Picture and AirPlay

    func testPiPButtonOnAVPlayer() {
        XCTAssertEqual(PhonePlayerSystem.pipAction(engine: .native, supported: true, active: false), .start)
        XCTAssertEqual(PhonePlayerSystem.pipAction(engine: .native, supported: true, active: true), .stop)
        XCTAssertEqual(PhonePlayerSystem.pipAction(engine: .native, supported: false, active: false), .hidden)
    }

    func testPiPButtonOnMpvOffersAVPlayer() {
        XCTAssertEqual(PhonePlayerSystem.pipAction(engine: .mpv, supported: false, active: false), .offerNative)
    }

    func testAirPlayButton() {
        XCTAssertEqual(PhonePlayerSystem.airPlayAction(engine: .native), .picker)
        XCTAssertEqual(PhonePlayerSystem.airPlayAction(engine: .mpv), .offerNative)
    }

    func testOfferWordsSayWhatTheButtonNeeds() {
        XCTAssertTrue(PhonePlayerSystem.offerMessage(for: .pictureInPicture).contains("AVPlayer"))
        XCTAssertTrue(PhonePlayerSystem.offerMessage(for: .airPlay).contains("AirPlay"))
        XCTAssertEqual(PhonePlayerSystem.offerButton(for: .airPlay), "Switch to AirPlay-capable engine")
    }

    // MARK: Torrent in the background

    func testTorrentNoteOnlyWhenATorrentStopped() {
        XCTAssertNotNil(PlayerSession.backgroundTorrentNote(isTorrent: true, playingNow: false))
        XCTAssertNil(PlayerSession.backgroundTorrentNote(isTorrent: true, playingNow: true), "it kept playing: nothing to say")
        XCTAssertNil(PlayerSession.backgroundTorrentNote(isTorrent: false, playingNow: false), "a paused file stream is the viewer's pause")
    }
}
