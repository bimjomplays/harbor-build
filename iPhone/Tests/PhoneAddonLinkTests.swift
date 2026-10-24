import XCTest
@testable import HarborPhone

/// The addon links the phone takes in (typed, pasted, scanned, a setup page's install link, a link
/// from another app) turned into the https manifest URL the engine reads.
final class PhoneAddonLinkTests: XCTestCase {
    private func n(_ raw: String) -> String? { PhoneAddonLink.normalize(raw) }

    // MARK: stremio:// and https

    func testStremioSchemeBecomesHttps() {
        XCTAssertEqual(n("stremio://v3-cinemeta.strem.io/manifest.json"), "https://v3-cinemeta.strem.io/manifest.json")
        XCTAssertEqual(n("STREMIO://Torrentio.Strem.FUN/manifest.json"), "https://torrentio.strem.fun/manifest.json",
                       "the scheme is matched in any case, the host lowercased")
    }

    func testHttpsAndHttpStayAsTheyAre() {
        XCTAssertEqual(n("https://opensubtitles-v3.strem.io/manifest.json"), "https://opensubtitles-v3.strem.io/manifest.json")
        XCTAssertEqual(n("http://192.168.1.20:11470/local/manifest.json"), "http://192.168.1.20:11470/local/manifest.json",
                       "a LAN addon keeps http and its port")
        XCTAssertEqual(n("HTTPS://Example.COM/Path/manifest.json"), "https://example.com/Path/manifest.json",
                       "scheme and host lowercased, the path left alone")
    }

    func testConfiguredPathIsKept() {
        let configured = "https://torrentio.strem.fun/providers=yts,eztv%7Cqualityfilter=480p/manifest.json"
        XCTAssertEqual(n(configured), configured)
        XCTAssertEqual(n("stremio://torrentio.strem.fun/providers=yts,eztv%7Cqualityfilter=480p/manifest.json"), configured)
    }

    func testRawBracesInAConfiguredPathAreEncoded() throws {
        let out = try XCTUnwrap(n(#"https://addon.example/{"debrid":"x"}/manifest.json"#))
        XCTAssertTrue(out.hasPrefix("https://addon.example/"), out)
        XCTAssertTrue(out.hasSuffix("/manifest.json"), out)
        XCTAssertNotNil(URL(string: out), "the result is a URL the engine can fetch")
    }

    // MARK: picked out of other text

    func testWhitespaceAroundTheLinkIsDropped() {
        XCTAssertEqual(n("  \n https://a.example/manifest.json \t\n"), "https://a.example/manifest.json")
    }

    func testLinkInsideASentenceOrBrackets() {
        XCTAssertEqual(n("Install it: https://a.example/x/manifest.json."), "https://a.example/x/manifest.json")
        XCTAssertEqual(n("(stremio://a.example/manifest.json)"), "https://a.example/manifest.json")
        XCTAssertEqual(n("<https://a.example/manifest.json>"), "https://a.example/manifest.json")
        XCTAssertEqual(n("\"https://a.example/manifest.json\""), "https://a.example/manifest.json")
        XCTAssertEqual(n("Addon: stremio://a.example/manifest.json see https://b.example/manifest.json"),
                       "https://a.example/manifest.json", "the first link wins")
    }

    func testWebStremioInstallLinkGivesTheAddon() {
        XCTAssertEqual(n("https://web.stremio.com/#/addons?addon=https%3A%2F%2Fa.example%2Fb%2Fmanifest.json"),
                       "https://a.example/b/manifest.json")
        XCTAssertEqual(n("https://web.stremio.com/#/addons?type=movie&addon=stremio%3A%2F%2Fa.example%2Fmanifest.json"),
                       "https://a.example/manifest.json")
    }

    // MARK: not a link

    func testNoLinkIsNil() {
        XCTAssertNil(n(""))
        XCTAssertNil(n("   "))
        XCTAssertNil(n("just some words"))
        XCTAssertNil(n("ftp://a.example/manifest.json"))
        XCTAssertNil(n("https://"), "no host")
        XCTAssertNil(n("stremio://"), "no host")
    }

    // MARK: helpers

    func testIsManifest() {
        XCTAssertTrue(PhoneAddonLink.isManifest("https://a.example/manifest.json"))
        XCTAssertTrue(PhoneAddonLink.isManifest("https://a.example/conf/Manifest.JSON"))
        XCTAssertFalse(PhoneAddonLink.isManifest("https://a.example/configure"))
        XCTAssertFalse(PhoneAddonLink.isManifest("https://a.example/manifest.json.bak"))
    }

    func testBase() {
        XCTAssertEqual(PhoneAddonLink.base(of: "https://a.example/x/manifest.json"), "https://a.example/x")
        XCTAssertEqual(PhoneAddonLink.base(of: "https://a.example/manifest.json"), "https://a.example")
        XCTAssertEqual(PhoneAddonLink.base(of: "https://a.example/x/"), "https://a.example/x")
    }
}
