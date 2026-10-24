import XCTest
@testable import HarborPhone

/// The Trackers screen's sign-in pieces as data: the web auth sheet's callback, a pasted code, the
/// approval page, the sign-in state the engine's status becomes, and the last-synced log.
@MainActor
final class PhoneTrackerAuthTests: XCTestCase {
    // MARK: Callback

    func testCallbackCodeInQuery() {
        let url = URL(string: "harbor-auth://anilist?code=abc123&state=x")!
        XCTAssertEqual(PhoneTrackerAuth.parseCallback(url), .code("abc123"))
    }

    func testCallbackCodeInFragment() {
        let url = URL(string: "harbor-auth://mal#code=def%2F456&state=y")!
        XCTAssertEqual(PhoneTrackerAuth.parseCallback(url), .code("def/456"))
    }

    func testCallbackDenied() {
        let url = URL(string: "harbor-auth://anilist?error=access_denied&error_description=The+user+said+no")!
        XCTAssertEqual(PhoneTrackerAuth.parseCallback(url), .denied("The user said no"))
        XCTAssertEqual(PhoneTrackerAuth.parseCallback(URL(string: "harbor-auth://mal?error=access_denied")!), .denied(nil))
    }

    func testCallbackWithoutCodeIsInvalid() {
        XCTAssertEqual(PhoneTrackerAuth.parseCallback(URL(string: "harbor-auth://anilist")!), .invalid)
        XCTAssertEqual(PhoneTrackerAuth.parseCallback(URL(string: "harbor-auth://anilist?code=")!), .invalid)
        XCTAssertEqual(PhoneTrackerAuth.parseCallback(URL(string: "harbor-auth://anilist?state=1")!), .invalid)
    }

    // MARK: Pasted code

    func testPastedPageAddress() {
        XCTAssertEqual(PhoneTrackerAuth.code(fromPasted: "https://anilist.co/api/v2/oauth/pin?code=AbC.123&x=1"), "AbC.123")
        XCTAssertEqual(PhoneTrackerAuth.code(fromPasted: "  https://example.com/cb#code=frag%20code "), "frag code")
    }

    func testPastedBareCode() {
        XCTAssertEqual(PhoneTrackerAuth.code(fromPasted: "  \"def456\"\n"), "def456")
        XCTAssertEqual(PhoneTrackerAuth.code(fromPasted: "ghi789"), "ghi789")
    }

    func testPastedNothing() {
        XCTAssertNil(PhoneTrackerAuth.code(fromPasted: ""))
        XCTAssertNil(PhoneTrackerAuth.code(fromPasted: "  \n "))
        XCTAssertNil(PhoneTrackerAuth.code(fromPasted: "\"\""))
    }

    // MARK: Approval page

    func testSimklApprovalCarriesTheCode() {
        let url = PhoneTrackerAuth.approvalURL(for: .simkl, userCode: "AB12C", verificationUrl: "https://simkl.com/pin")
        XCTAssertEqual(url?.absoluteString, "https://simkl.com/pin/AB12C")
    }

    func testTraktApprovalIsTheServicesPage() {
        let url = PhoneTrackerAuth.approvalURL(for: .trakt, userCode: "AB12C", verificationUrl: "https://trakt.tv/activate")
        XCTAssertEqual(url?.absoluteString, "https://trakt.tv/activate")
    }

    func testDeviceCodeEndRereadsWhateverTheSharedStatusSays() {
        // Approved / denied / expired / cancelled: the code goes away, and the page reads the state
        // again (TraktModel's own status is still the old one at that moment).
        XCTAssertTrue(PhoneTrackerAuth.deviceCodeEnded(from: "dev-1", to: nil))
        // A new code, or a first one, is no verdict.
        XCTAssertFalse(PhoneTrackerAuth.deviceCodeEnded(from: nil, to: "dev-1"))
        XCTAssertFalse(PhoneTrackerAuth.deviceCodeEnded(from: "dev-1", to: "dev-2"))
        XCTAssertFalse(PhoneTrackerAuth.deviceCodeEnded(from: nil, to: nil))
    }

    func testWebURLTakesOnlyWebPages() {
        XCTAssertNotNil(PhoneTrackerAuth.webURL("https://anilist.co/api/v2/oauth/authorize?x=1"))
        XCTAssertNotNil(PhoneTrackerAuth.webURL(" http://example.com "))
        XCTAssertNil(PhoneTrackerAuth.webURL(nil))
        XCTAssertNil(PhoneTrackerAuth.webURL(""))
        XCTAssertNil(PhoneTrackerAuth.webURL("javascript:alert(1)"))
        XCTAssertNil(PhoneTrackerAuth.webURL("harbor-auth://anilist"))
        XCTAssertNil(PhoneTrackerAuth.webURL("https://"))
    }

    // MARK: State

    func testStateFromStatus() {
        XCTAssertEqual(PhoneTrackerState(authenticated: true, username: "kai", reconnect: nil), .connected(username: "kai"))
        XCTAssertEqual(PhoneTrackerState(authenticated: true, username: "  ", reconnect: false), .connected(username: nil))
        XCTAssertEqual(PhoneTrackerState(authenticated: false, username: nil, reconnect: nil), .signedOut)
        // A stored but expired session is a reconnect, whatever `authenticated` says.
        XCTAssertEqual(PhoneTrackerState(authenticated: false, username: "kai", reconnect: true), .reconnect(username: "kai"))
        XCTAssertEqual(PhoneTrackerState(authenticated: true, username: nil, reconnect: true), .reconnect(username: nil))
    }

    func testStateSessionAndTitles() {
        XCTAssertFalse(PhoneTrackerState.signedOut.hasSession)
        XCTAssertTrue(PhoneTrackerState.connected(username: nil).hasSession)
        XCTAssertTrue(PhoneTrackerState.reconnect(username: "kai").hasSession)
        XCTAssertEqual(PhoneTrackerState.reconnect(username: "kai").username, "kai")

        XCTAssertEqual(PhoneTrackerState.signedOut.title(for: .mal), "Not connected")
        XCTAssertEqual(PhoneTrackerState.reconnect(username: "kai").title(for: .trakt), "Reconnect needed")
        XCTAssertEqual(PhoneTrackerState.connected(username: "kai").title(for: .trakt), "Connected as @kai")
        XCTAssertEqual(PhoneTrackerState.connected(username: "kai").title(for: .simkl), "Connected as kai")
        XCTAssertEqual(PhoneTrackerState.connected(username: nil).title(for: .anilist), "Connected to AniList")
    }

    func testEveryTrackerHasAFlow() {
        XCTAssertEqual(PhoneTracker.allCases.map(\.label), ["Trakt", "Simkl", "AniList", "MyAnimeList", "Letterboxd"])
        XCTAssertEqual(PhoneTracker.anilist.homeRails.count, 5)
        XCTAssertEqual(PhoneTracker.anilist.homeSource(railKey: "watching")?.identity, HomeRowSource.anilistList(railKey: "watching").identity)
        XCTAssertNil(PhoneTracker.simkl.homeSource(railKey: "watching"))
    }

    // MARK: Sync log

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "phone.trackers.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testSyncLogRecordsAndClears() {
        withDefaults { defaults in
            let log = PhoneTrackerSyncLog(defaults: defaults)
            XCTAssertNil(log.date(for: .simkl))
            let when = Date(timeIntervalSince1970: 1_800_000_000)
            log.record(.simkl, at: when)
            XCTAssertEqual(log.date(for: .simkl), when)
            XCTAssertNil(log.date(for: .anilist))
            log.clear(.simkl)
            XCTAssertNil(log.date(for: .simkl))
        }
    }

    func testSyncText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(PhoneTrackerSyncLog.text(nil, now: now, locale: english), "Never synced")
        XCTAssertEqual(PhoneTrackerSyncLog.text(now.addingTimeInterval(-20), now: now, locale: english), "Synced just now")
        XCTAssertEqual(PhoneTrackerSyncLog.text(now.addingTimeInterval(-5 * 60), now: now, locale: english), "Synced 5 minutes ago")
    }

    // MARK: Model on fixtures

    func testFixtureSignOutClearsTheSession() async {
        let name = "phone.trackers.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let log = PhoneTrackerSyncLog(defaults: defaults)
        log.record(.simkl)
        let model = PhoneTrackersModel(fixtures: true, log: log)
        await model.refresh()
        XCTAssertEqual(model.state(.simkl), .connected(username: "harbor-fan"))
        XCTAssertNotNil(model.lists[.simkl])

        await model.signOut(.simkl)
        XCTAssertEqual(model.state(.simkl), .signedOut)
        XCTAssertNil(model.lists[.simkl])
        XCTAssertNil(model.lastSynced(.simkl))
        // A refresh on the same screen keeps the sign-out.
        await model.refresh()
        XCTAssertEqual(model.state(.simkl), .signedOut)
        XCTAssertEqual(model.state(.anilist), .connected(username: "HarborFan"))
    }

    func testSignOutDisconnectsThroughTheCallersModel() async {
        // The page passes its own models' disconnect so their "Connected as …" note goes with the session.
        let name = "phone.trackers.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = PhoneTrackersModel(fixtures: true, log: PhoneTrackerSyncLog(defaults: defaults))
        await model.refresh()
        let calls = NSMutableArray()
        await model.signOut(.simkl, disconnect: { calls.add(1) })
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(model.state(.simkl), .signedOut)
    }

    func testFixtureSyncStampsOnlyASession() async {
        let name = "phone.trackers.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = PhoneTrackersModel(fixtures: true, log: PhoneTrackerSyncLog(defaults: defaults))
        await model.refresh()
        let didSyncMal = await model.sync(.mal)
        XCTAssertFalse(didSyncMal)
        XCTAssertNil(model.lastSynced(.mal))
        let didSyncAnilist = await model.sync(.anilist)
        XCTAssertTrue(didSyncAnilist)
        XCTAssertNotNil(model.lastSynced(.anilist))
    }
}
