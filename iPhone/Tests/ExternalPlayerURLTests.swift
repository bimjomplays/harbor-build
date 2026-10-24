import XCTest
@testable import HarborPhone

/// The external players' play URLs (ExternalPlayer), each checked against the format on
/// the vendor's page, plus which resolved links another app can reach and the way back.
final class ExternalPlayerURLTests: XCTestCase {
    /// A stream URL with its own query, an encoded slash and a plus: all of it must reach the player
    /// as one value.
    private let stream = URL(string: "https://cdn.example.com/v/Film.mkv?token=a%2Fb&exp=1+2")!
    private let streamEncoded = "https%3A%2F%2Fcdn.example.com%2Fv%2FFilm.mkv%3Ftoken%3Da%252Fb%26exp%3D1%2B2"
    private let sub = URL(string: "https://subs.example.com/en.srt")!
    private let subEncoded = "https%3A%2F%2Fsubs.example.com%2Fen.srt"
    private let ok = URL(string: "harbor://external-played/T1")!
    private let okEncoded = "harbor%3A%2F%2Fexternal-played%2FT1"
    private let bad = URL(string: "harbor://external-failed/T1")!
    private let badEncoded = "harbor%3A%2F%2Fexternal-failed%2FT1"

    private func full(position: Int? = 125) -> ExternalPlayer.Request {
        ExternalPlayer.Request(url: stream, subtitle: sub, filename: "Dune Part Two (2024).mkv",
                               positionSec: position, onSuccess: ok, onError: bad)
    }

    /// The query items the player decodes (each value decoded once).
    private func items(_ url: URL?) -> [String: String] {
        let list: [URLQueryItem] = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(list.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: each player's URL

    func testInfuseURL() {
        let url = ExternalPlayer.infuse.playURL(full())
        XCTAssertEqual(url?.absoluteString,
                       "infuse://x-callback-url/play?url=\(streamEncoded)&position=125"
                       + "&filename=Dune%20Part%20Two%20%282024%29.mkv&sub=\(subEncoded)"
                       + "&x-success=\(okEncoded)&x-error=\(badEncoded)")
        let q = items(url)
        XCTAssertEqual(q["url"], stream.absoluteString, "the stream URL is not encoded exactly once")
        XCTAssertEqual(q["sub"], sub.absoluteString)
        XCTAssertEqual(q["filename"], "Dune Part Two (2024).mkv")
        XCTAssertEqual(q["x-success"], ok.absoluteString)
    }

    func testVLCURL() {
        // VLC's x-callback form takes the stream and the two callbacks, nothing else.
        let url = ExternalPlayer.vlc.playURL(full())
        XCTAssertEqual(url?.absoluteString,
                       "vlc-x-callback://x-callback-url/stream?url=\(streamEncoded)&x-success=\(okEncoded)&x-error=\(badEncoded)")
        let q = items(url)
        XCTAssertEqual(q["url"], stream.absoluteString)
        XCTAssertNil(q["position"])
        XCTAssertNil(q["sub"])
        XCTAssertNil(q["filename"])
        XCTAssertFalse(ExternalPlayer.vlc.takesPosition)
        XCTAssertFalse(ExternalPlayer.vlc.takesSubtitle)
    }

    func testVidHubURL() {
        let url = ExternalPlayer.vidhub.playURL(full())
        XCTAssertEqual(url?.absoluteString,
                       "open-vidhub://x-callback-url/play?url=\(streamEncoded)&position=125"
                       + "&filename=Dune%20Part%20Two%20%282024%29.mkv&sub=\(subEncoded)"
                       + "&x-success=\(okEncoded)&x-error=\(badEncoded)&x-cancel=\(okEncoded)&x-source=Harbor")
        let q = items(url)
        XCTAssertEqual(q["url"], stream.absoluteString, "VidHub decodes once: the value must not be encoded twice")
        XCTAssertEqual(q["x-cancel"], ok.absoluteString)
    }

    func testStreamOnly() {
        let bare = ExternalPlayer.Request(url: URL(string: "https://cdn.example.com/a.mp4")!)
        let encoded = "https%3A%2F%2Fcdn.example.com%2Fa.mp4"
        XCTAssertEqual(ExternalPlayer.infuse.playURL(bare)?.absoluteString, "infuse://x-callback-url/play?url=\(encoded)")
        XCTAssertEqual(ExternalPlayer.vlc.playURL(bare)?.absoluteString, "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
        XCTAssertEqual(ExternalPlayer.vidhub.playURL(bare)?.absoluteString, "open-vidhub://x-callback-url/play?url=\(encoded)&x-source=Harbor")
    }

    // MARK: rules

    func testPositionRules() {
        for p in [nil, 0, -3] as [Int?] {
            XCTAssertNil(items(ExternalPlayer.infuse.playURL(full(position: p)))["position"], "Infuse got position \(String(describing: p))")
            XCTAssertNil(items(ExternalPlayer.vidhub.playURL(full(position: p)))["position"], "VidHub got position \(String(describing: p))")
        }
        // VidHub accepts 0 to 31536000 seconds.
        XCTAssertEqual(items(ExternalPlayer.vidhub.playURL(full(position: 31_536_000)))["position"], "31536000")
        XCTAssertNil(items(ExternalPlayer.vidhub.playURL(full(position: 31_536_001)))["position"])
        XCTAssertEqual(items(ExternalPlayer.infuse.playURL(full(position: 31_536_001)))["position"], "31536001")
    }

    func testEmptyFilenameIsLeftOut() {
        var r = full()
        r.filename = ""
        XCTAssertNil(items(ExternalPlayer.infuse.playURL(r))["filename"])
        XCTAssertNil(items(ExternalPlayer.vidhub.playURL(r))["filename"])
    }

    func testEncodeKeepsOnlyUnreserved() {
        XCTAssertEqual(ExternalPlayer.encode("aZ09-._~"), "aZ09-._~")
        XCTAssertEqual(ExternalPlayer.encode("a b?c&d=e+f%g/h:i#j"), "a%20b%3Fc%26d%3De%2Bf%25g%2Fh%3Ai%23j")
        XCTAssertEqual(ExternalPlayer.encode("é"), "%C3%A9")
    }

    func testSchemesAndProbes() {
        XCTAssertEqual(ExternalPlayer.allCases, [.infuse, .vlc, .vidhub], "Infuse goes first")
        XCTAssertEqual(ExternalPlayer.allCases.map(\.scheme), ["infuse", "vlc-x-callback", "open-vidhub"])
        XCTAssertEqual(ExternalPlayer.allCases.map(\.probeURL.absoluteString), ["infuse://", "vlc-x-callback://", "open-vidhub://"])
    }

    /// Every scheme canOpenURL asks about is declared in the app's Info.plist, or iOS answers false.
    func testSchemesAreDeclared() throws {
        let declared = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])
        for p in ExternalPlayer.allCases {
            XCTAssertTrue(declared.contains(p.scheme), "\(p.scheme) is not in LSApplicationQueriesSchemes")
        }
    }

    // MARK: reach

    func testReach() {
        let plain = "https://cdn.example.com/a.mkv"
        XCTAssertEqual(ExternalReach.check(url: plain, headers: nil, via: "debrid", homeServer: false), .reachable(URL(string: plain)!))
        XCTAssertEqual(ExternalReach.check(url: "http://cdn.example.com/a.mkv", headers: [:], via: nil, homeServer: false),
                       .reachable(URL(string: "http://cdn.example.com/a.mkv")!))
        XCTAssertEqual(ExternalReach.check(url: plain, headers: ["Referer": ""], via: nil, homeServer: false),
                       .reachable(URL(string: plain)!), "an empty header is no header")
        XCTAssertEqual(ExternalReach.check(url: plain, headers: ["Authorization": "Bearer x"], via: nil, homeServer: false), .needsHeaders)
        XCTAssertEqual(ExternalReach.check(url: plain, headers: nil, via: "p2p", homeServer: false), .local)
        XCTAssertEqual(ExternalReach.check(url: plain, headers: nil, via: nil, homeServer: true), .homeServer)
        for local in ["http://127.0.0.1:11470/x/0", "http://localhost:8080/a", "http://[::1]:9000/a", "http://0.0.0.0/a", "http://harbor.localhost/a"] {
            XCTAssertEqual(ExternalReach.check(url: local, headers: nil, via: nil, homeServer: false), .local, local)
        }
        for odd in ["magnet:?xt=urn:btih:abc", "rtsp://cam.example.com/live", "", "file:///tmp/a.mkv", "https://"] {
            XCTAssertEqual(ExternalReach.check(url: odd, headers: nil, via: nil, homeServer: false), .notWeb, odd)
        }
        XCTAssertNil(ExternalReach.reachable(URL(string: plain)!).reason)
        for r in [ExternalReach.local, .needsHeaders, .homeServer, .notWeb] { XCTAssertNotNil(r.reason) }
    }

    func testRowMayReach() {
        XCTAssertFalse(ExternalReach.rowMayReach(availability: "p2p", url: nil))
        XCTAssertFalse(ExternalReach.rowMayReach(availability: "cached", url: "magnet:?xt=urn:btih:abc"))
        XCTAssertTrue(ExternalReach.rowMayReach(availability: "cached", url: nil), "a debrid row resolves to its link later")
        XCTAssertTrue(ExternalReach.rowMayReach(availability: "external", url: "https://cdn.example.com/a.mkv"))
    }

    // MARK: the way back

    func testInfuseCallback() throws {
        let back = try XCTUnwrap(PhoneExternalPlay.Callback.parse(URL(string: "harbor://external-played/T1?lastPlayedUrl=https%3A%2F%2Fcdn.example.com%2Fa.mkv&position=812")!))
        XCTAssertEqual(back, .init(failed: false, token: "T1", positionSec: 812, durationSec: nil, finished: false, errorMessage: nil))
    }

    func testVidHubCallback() throws {
        let back = try XCTUnwrap(PhoneExternalPlay.Callback.parse(URL(string: "harbor://external-played/T2?lastPlayedUrl=x&position=5390&duration=5400&status=finished")!))
        XCTAssertEqual(back, .init(failed: false, token: "T2", positionSec: 5390, durationSec: 5400, finished: true, errorMessage: nil))
    }

    func testVLCCallbackAndFailure() throws {
        let vlc = try XCTUnwrap(PhoneExternalPlay.Callback.parse(URL(string: "harbor://external-played/T3")!))
        XCTAssertEqual(vlc, .init(failed: false, token: "T3", positionSec: nil, durationSec: nil, finished: false, errorMessage: nil))
        let failed = try XCTUnwrap(PhoneExternalPlay.Callback.parse(URL(string: "harbor://external-failed/T4?errorCode=1&errorMessage=Unsupported%20format")!))
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.token, "T4")
        XCTAssertEqual(failed.errorMessage, "Unsupported format")
    }

    func testOtherLinksAreNotCallbacks() {
        XCTAssertNil(PhoneExternalPlay.Callback.parse(URL(string: "harbor://detail/movie/tt0000001")!))
        XCTAssertNil(PhoneExternalPlay.Callback.parse(URL(string: "stremio://external-played/T1")!))
    }

    // MARK: the setting

    func testChoiceIsSavedPerProfile() {
        let a = "test-653-a", b = "test-653-b"
        defer {
            Prefs.remove(PhonePlayerChoice.key(for: a))
            Prefs.remove(PhonePlayerChoice.key(for: b))
        }
        XCTAssertNil(PhonePlayerChoice.saved(for: a), "Harbor's player is the default")
        PhonePlayerChoice.save(.infuse, for: a)
        XCTAssertEqual(PhonePlayerChoice.saved(for: a), .infuse)
        XCTAssertNil(PhonePlayerChoice.saved(for: b), "one profile's choice leaked to another")
        PhonePlayerChoice.save(.vidhub, for: b)
        PhonePlayerChoice.save(nil, for: a)
        XCTAssertNil(PhonePlayerChoice.saved(for: a))
        XCTAssertEqual(PhonePlayerChoice.saved(for: b), .vidhub)
    }
}
