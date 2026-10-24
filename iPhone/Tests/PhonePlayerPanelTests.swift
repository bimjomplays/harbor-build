import XCTest
@testable import HarborPhone

/// The phone player's panel sheets (iPhone/Sources/Player/Panels): which panels a title
/// gets, the audio lane's selection and sync, the speed and sleep lists with the timer's countdown, the
/// lock, the quality press and the stats rows.
@MainActor
final class PhonePlayerPanelTests: XCTestCase {
    override func tearDown() {
        SleepTimer.shared.clear()
        super.tearDown()
    }

    // MARK: Which panels

    func testEveryTitleGetsSubtitlesAudioAndSpeedStatsAndNothingElse() {
        let shown = PhonePlayerPanel.shown(.init())
        XCTAssertEqual(shown, [.subtitles, .audio, .speed, .stats])
    }

    func testSourcesQualityAndXRayFollowTheirFacts() {
        let all = PhonePlayerPanel.shown(.init(isLive: false, hasHomeServer: true, sources: .sheet, xray: true, isKid: false))
        XCTAssertEqual(all, [.subtitles, .audio, .speed, .sources, .quality, .stats, .xray])
        // Live has no home-server quality; no X-Ray unless the setting is on.
        let live = PhonePlayerPanel.shown(.init(isLive: true, hasHomeServer: true, sources: .none, xray: false, isKid: false))
        XCTAssertEqual(live, [.subtitles, .audio, .speed, .stats])
    }

    func testKidsGetNoStatsOrXRay() {
        let kid = PhonePlayerPanel.shown(.init(isLive: false, hasHomeServer: false, sources: .reopen, xray: true, isKid: true))
        XCTAssertEqual(kid, [.subtitles, .audio, .speed, .sources])
    }

    func testSourcesRoute() {
        XCTAssertEqual(PhonePlayerPanel.sourcesRoute(canSwitchInPlace: true, canReopen: true), .sheet)
        XCTAssertEqual(PhonePlayerPanel.sourcesRoute(canSwitchInPlace: false, canReopen: true), .reopen)
        XCTAssertEqual(PhonePlayerPanel.sourcesRoute(canSwitchInPlace: false, canReopen: false), .none)
    }

    func testSessionPanelsRoundTrip() {
        for p in PhonePlayerPanel.allCases {
            guard let s = p.sessionPanel else {
                XCTAssertTrue(p == .stats || p == .xray)
                continue
            }
            XCTAssertEqual(PhonePlayerPanel(s), p)
        }
        XCTAssertNil(PhonePlayerPanel(.anime4k))
        XCTAssertNil(PhonePlayerPanel(.channels))
    }

    func testIdentifiersAreDistinct() {
        let ids = PhonePlayerPanel.allCases.flatMap { [$0.buttonID, $0.sheetID] }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(PhonePlayerPanel.audio.buttonID, "player-panel-audio")
        XCTAssertEqual(PhonePlayerPanel.audio.sheetID, "player-sheet-audio")
    }

    // MARK: Audio

    func testAudioListsOnlyAudioTracksAndSelectionMovesOne() {
        let engine = PhoneFixtureEngine(kind: .mpv)
        var written: [Double] = []
        let model = PhoneAudioModel(controller: engine, delay: 0, onDelay: { written.append($0) })
        XCTAssertEqual(model.tracks.map(\.id), [1, 2])
        XCTAssertEqual(model.tracks.first { $0.selected }?.id, 1)
        model.select(model.tracks[1])
        XCTAssertEqual(model.tracks.first { $0.selected }?.id, 2, "the Japanese track plays")
        XCTAssertEqual(engine.tracks().filter { $0.type == "audio" && $0.selected }.count, 1)
        XCTAssertTrue(written.isEmpty, "a track pick does not touch the sync offset")
    }

    func testAudioDelayStepsRoundAndReachTheSessionAndEngine() {
        let engine = PhoneFixtureEngine(kind: .mpv)
        var written: [Double] = []
        let model = PhoneAudioModel(controller: engine, delay: 0, onDelay: { written.append($0) })
        model.nudge(by: 0.1)
        model.nudge(by: 0.1)
        model.nudge(by: 0.1)
        XCTAssertEqual(model.delay, 0.3, accuracy: 1e-9)
        XCTAssertEqual(written.last ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(model.delayLabel, "+0.30s")
        model.nudge(by: -0.5)
        XCTAssertEqual(model.delayLabel, "-0.20s")
        model.setDelay(0)
        XCTAssertEqual(model.delayLabel, "0.00s")
        XCTAssertEqual(written.last, 0)
    }

    func testAudioDelayIsLockedOnAVPlayer() {
        XCTAssertTrue(PhoneAudioModel(controller: PhoneFixtureEngine(kind: .native), delay: 0, onDelay: { _ in }).delayLocked)
        XCTAssertFalse(PhoneAudioModel(controller: PhoneFixtureEngine(kind: .mpv), delay: 0, onDelay: { _ in }).delayLocked)
    }

    func testAudioModelWithNoEngineIsEmpty() {
        let model = PhoneAudioModel(controller: nil, delay: 0, onDelay: { _ in })
        XCTAssertTrue(model.tracks.isEmpty)
        XCTAssertNil(model.engineKey)
        model.use(PhoneFixtureEngine(kind: .mpv))
        XCTAssertEqual(model.tracks.count, 2, "a new engine's tracks are read at once")
    }

    func testAudioHeaderLine() {
        let model = PhoneAudioModel(controller: PhoneFixtureEngine(kind: .mpv), delay: 0, onDelay: { _ in })
        XCTAssertTrue(model.headerLine(title: "Dune").hasPrefix("Dune · "))
        XCTAssertFalse(model.headerLine(title: "").contains("·"))
    }

    func testTrackText() {
        let t = MPVPlayerController.Track(id: 1, type: "audio", lang: "eng", title: "English", codec: "ac3", selected: true, isDefault: true, channels: "5.1")
        let l = PhoneTrackText.lines(t)
        XCTAssertEqual(l.head, "English")
        XCTAssertTrue(l.detail.contains("AC3"))
        XCTAssertTrue(l.detail.contains("5.1"))
        // A title that is only the language code falls back to the language's name.
        let bare = MPVPlayerController.Track(id: 2, type: "audio", lang: "jpn", title: "jpn", codec: nil, selected: false)
        XCTAssertEqual(PhoneTrackText.lines(bare).head, "Japanese")
        XCTAssertEqual(PhoneTrackText.onLabel([t, bare], type: "audio"), "English")
        XCTAssertNil(PhoneTrackText.onLabel([t, bare], type: "sub"))
    }

    // MARK: Speed

    func testSpeedListHoldsTheCuratedAndTheViewersOwnSorted() {
        XCTAssertEqual(PhoneSpeedSleep.speeds(custom: nil), [0.75, 1, 1.25, 1.5, 2])
        XCTAssertEqual(PhoneSpeedSleep.speeds(custom: [1.75, 3, 1.5]), [0.75, 1, 1.25, 1.5, 1.75, 2, 3])
        XCTAssertEqual(PhoneSpeedSleep.speeds(custom: [0, 9, .nan]), PhoneSpeedSleep.curatedSpeeds, "a speed no engine plays is skipped")
    }

    func testRateLabelAndSelection() {
        XCTAssertEqual(PhoneSpeedSleep.rateLabel(1.5), "1.5×")
        XCTAssertEqual(PhoneSpeedSleep.rateLabel(1), PhoneSpeedSleep.rateLabel(1.0001))
        XCTAssertTrue(PhoneSpeedSleep.isRate(1.5, 1.5))
        XCTAssertFalse(PhoneSpeedSleep.isRate(1.5, 2))
    }

    func testTheSpeedButtonFace() {
        XCTAssertNil(PhoneSpeedSleep.face(rate: 1, isLive: false, sleepFace: nil))
        XCTAssertEqual(PhoneSpeedSleep.face(rate: 1.5, isLive: false, sleepFace: nil), "1.5×")
        XCTAssertNil(PhoneSpeedSleep.face(rate: 1.5, isLive: true, sleepFace: nil), "a live stream has no speed")
        XCTAssertEqual(PhoneSpeedSleep.face(rate: 1.5, isLive: false, sleepFace: "12:30"), "12:30", "the countdown wins")
    }

    // MARK: Sleep

    func testSleepMinutesAndRows() {
        XCTAssertEqual(PhoneSpeedSleep.sleepMinutes(custom: nil), [30, 60])
        XCTAssertEqual(PhoneSpeedSleep.sleepMinutes(custom: [45, 30, 0, 90.4]), [30, 45, 60, 90])
        let rows = PhoneSpeedSleep.sleepRows(minutes: [30, 60])
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.isMinutes), [true, true, false, false])
        XCTAssertEqual(rows[0].label, SleepTimer.minuteLabel(30))
    }

    func testSleepSelectionMatchesOnTotalOrKind() {
        let rows = PhoneSpeedSleep.sleepRows(minutes: [30, 60])
        let armed = SleepTimer.Mode.minutes(total: 30, firesAt: Date().addingTimeInterval(1800))
        XCTAssertTrue(PhoneSpeedSleep.isSelected(armed, rows[0].mode))
        XCTAssertFalse(PhoneSpeedSleep.isSelected(armed, rows[1].mode))
        XCTAssertTrue(PhoneSpeedSleep.isSelected(.endEpisode, rows[2].mode))
        XCTAssertTrue(PhoneSpeedSleep.isSelected(.endNextEpisode(remaining: 1), rows[3].mode))
        XCTAssertFalse(PhoneSpeedSleep.isSelected(.off, rows[2].mode))
    }

    func testSleepTimerCountsDownAndFeedsTheFace() {
        let timer = SleepTimer.shared
        timer.clear()
        XCTAssertNil(timer.faceLabel)
        timer.set(PhoneSpeedSleep.sleepRows(minutes: [30])[0].mode)
        XCTAssertTrue(timer.isActive)
        let left = timer.remainingSec ?? 0
        XCTAssertGreaterThan(left, 29 * 60)
        XCTAssertLessThanOrEqual(left, 30 * 60)
        XCTAssertEqual(timer.faceLabel, SleepTimer.formatRemaining(left))
        XCTAssertTrue(PhoneSpeedSleep.isSelected(timer.mode, .minutes(total: 30, firesAt: Date())))
        timer.clear()
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.remainingSec)
    }

    func testSleepTimerEndOfEpisodeHasNoCountdown() {
        let timer = SleepTimer.shared
        timer.set(.endEpisode)
        XCTAssertNil(timer.remainingSec)
        XCTAssertEqual(timer.mode, .endEpisode)
        XCTAssertNotNil(timer.faceLabel)
    }

    func testFormatRemaining() {
        XCTAssertEqual(SleepTimer.formatRemaining(0), "0:00")
        XCTAssertEqual(SleepTimer.formatRemaining(59.6), "1:00")
        XCTAssertEqual(SleepTimer.formatRemaining(1805), "30:05")
    }

    // MARK: Lock

    func testLockBlocksTouchesAndUnlockRestoresThem() {
        var lock = PhonePlayerLock()
        XCTAssertTrue(lock.passesTouches)
        lock.touched()
        XCTAssertFalse(lock.hintShown, "an unlocked player has no Unlock button")
        lock.lock()
        XCTAssertTrue(lock.locked)
        XCTAssertFalse(lock.passesTouches)
        XCTAssertFalse(lock.hintShown)
        lock.touched()
        XCTAssertTrue(lock.hintShown, "a touch on the locked player brings up Unlock")
        lock.hintExpired()
        XCTAssertFalse(lock.hintShown)
        XCTAssertTrue(lock.locked)
        lock.touched()
        lock.unlock()
        XCTAssertFalse(lock.locked)
        XCTAssertTrue(lock.passesTouches)
        XCTAssertFalse(lock.hintShown)
    }

    func testLockingHidesAnOpenHint() {
        var lock = PhonePlayerLock()
        lock.lock()
        lock.touched()
        lock.lock()
        XCTAssertFalse(lock.hintShown)
    }

    // MARK: Quality

    func testQualityPress() {
        let model = PhoneQualityModel()
        XCTAssertEqual(model.press("original"), .close, "the one playing just closes the sheet")
        XCTAssertEqual(model.press("720p"), .switchTo("720p"))
    }

    // MARK: Stats

    func testStatsSourceKeepsOnlyTheHostAndExtension() {
        let url = URL(string: "https://cdn.example.com/dl/SECRET-TOKEN/movie.mkv?sig=SECRET")!
        XCTAssertEqual(PhoneStats.source(url), "cdn.example.com .mkv")
        XCTAssertEqual(PhoneStats.source(URL(fileURLWithPath: "/tmp/a.mp4")), "file .mp4")
    }

    func testStatsRowsNeverCarryTheFullURL() {
        let url = URL(string: "https://cdn.example.com/dl/SECRET-TOKEN/movie.mkv?sig=SECRET")!
        var status = MPVPlayerController.Status()
        status.state = "playing"
        status.videoParams = "1920x1080 yuv420p"
        status.vo = "gpu-next"
        status.hwdec = "videotoolbox"
        status.fps = "23.976"
        status.dropped = "2"
        let rows = PhoneStats.rows(engine: .mpv, url: url, status: status, position: 65, duration: 7200, buffered: 90, rate: 1.5)
        XCTAssertFalse(rows.contains { $0.value.contains("SECRET") })
        XCTAssertEqual(rows.first { $0.label == T("Engine") }?.value, "mpv")
        XCTAssertEqual(rows.first { $0.label == T("Position") }?.value, "\(PlayerClock.fmt(65)) / \(PlayerClock.fmt(7200))")
        XCTAssertEqual(rows.first { $0.label == T("Speed") }?.value, "1.5×")
        XCTAssertEqual(rows.first { $0.label == T("Output") }?.value, "vo=gpu-next hwdec=videotoolbox")
        XCTAssertNotNil(rows.first { $0.label == T("Dropped frames") })
    }

    func testStatsRowsStayShortWhenTheEngineHasNothingToSay() {
        let url = URL(string: "https://cdn.example.com/a.mp4")!
        let rows = PhoneStats.rows(engine: .native, url: url, status: .init(), position: 0, duration: 0, buffered: 0, rate: 1)
        XCTAssertEqual(rows.map(\.label), [T("Engine"), T("Source"), T("State")])
        XCTAssertEqual(rows.first?.value, "AVPlayer")
    }

    func testStatsStateCarriesTheEnginesError() {
        var status = MPVPlayerController.Status()
        status.state = "error"
        status.error = "boom"
        let rows = PhoneStats.rows(engine: .mpv, url: URL(string: "https://h/a.mp4")!, status: status, position: 0, duration: 0, buffered: 0, rate: 1)
        XCTAssertEqual(rows.first { $0.label == T("State") }?.value, "error — boom")
    }

    func testStatsLogIsTheLastLines() {
        var status = MPVPlayerController.Status()
        status.log = (1...25).map { "line \($0)" }
        let log = PhoneStats.log(status)
        XCTAssertEqual(log.count, 10)
        XCTAssertEqual(log.last, "line 25")
    }
}
