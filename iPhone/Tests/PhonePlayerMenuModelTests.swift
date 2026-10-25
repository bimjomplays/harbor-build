import XCTest
@testable import HarborPhone

/// The gear menu's words and lists (iPhone/Sources/Player/PhonePlayerMenuModel.swift), named the way
/// Infuse names them: "English - E-AC3 5.1", "Normal", "+150%", "None".
final class PhonePlayerMenuModelTests: XCTestCase {
    private typealias Track = MPVPlayerController.Track

    private func audio(_ id: Int, _ lang: String?, _ title: String?, _ codec: String?, _ channels: String?,
                       selected: Bool = false, isDefault: Bool = false) -> Track {
        Track(id: id, type: "audio", lang: lang, title: title, codec: codec, selected: selected, isDefault: isDefault, channels: channels)
    }

    private func sub(_ id: Int, _ lang: String?, _ title: String?, selected: Bool = false, forced: Bool = false,
                     hearingImpaired: Bool = false, isDefault: Bool = false) -> Track {
        Track(id: id, type: "sub", lang: lang, title: title, codec: "subrip", selected: selected, forced: forced,
              hearingImpaired: hearingImpaired, isDefault: isDefault)
    }

    // MARK: Volume boost

    func testBoostSteps() {
        XCTAssertEqual(PhonePlayerMenuModel.boostSteps, [0, 50, 100, 150, 200, 250, 300])
        XCTAssertEqual(PhonePlayerMenuModel.boostLabel(0), "Disabled")
        XCTAssertEqual(PhonePlayerMenuModel.boostLabel(150), "+150%")
    }

    // MARK: Speed

    func testSpeedsAreTheQuarterStepsPlusTheViewersOwn() {
        XCTAssertEqual(PhonePlayerMenuModel.speeds(custom: nil), [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        XCTAssertEqual(PhonePlayerMenuModel.speeds(custom: [1.1, 1.5, 9, .nan]), [0.25, 0.5, 0.75, 1, 1.1, 1.25, 1.5, 1.75, 2])
    }

    func testSpeedLabels() {
        XCTAssertEqual(PhonePlayerMenuModel.speedLabel(1), "Normal")
        XCTAssertEqual(PhonePlayerMenuModel.speedLabel(1.25), "1.25x")
        XCTAssertEqual(PhonePlayerMenuModel.speedLabel(0.5), "0.5x")
        XCTAssertEqual(PhonePlayerMenuModel.speedLabel(2), "2x")
    }

    // MARK: Codecs and channels

    func testCodecNames() {
        XCTAssertEqual(PhonePlayerMenuModel.codecName("eac3"), "E-AC3")
        XCTAssertEqual(PhonePlayerMenuModel.codecName("truehd"), "TrueHD")
        XCTAssertEqual(PhonePlayerMenuModel.codecName("hdmv_pgs_subtitle"), "PGS")
        XCTAssertEqual(PhonePlayerMenuModel.codecName("xyz"), "XYZ")
        XCTAssertNil(PhonePlayerMenuModel.codecName(" "))
        XCTAssertNil(PhonePlayerMenuModel.codecName(nil))
    }

    func testChannelNames() {
        XCTAssertEqual(PhonePlayerMenuModel.channelsName("5.1(side)"), "5.1")
        XCTAssertEqual(PhonePlayerMenuModel.channelsName("7.1"), "7.1")
        XCTAssertEqual(PhonePlayerMenuModel.channelsName("stereo"), "2.0")
        XCTAssertEqual(PhonePlayerMenuModel.channelsName("mono"), "1.0")
        XCTAssertNil(PhonePlayerMenuModel.channelsName(""))
    }

    // MARK: Audio

    func testAudioHeadReadsLikeInfuse() {
        XCTAssertEqual(PhonePlayerMenuModel.audioHead(audio(1, "eng", "English", "eac3", "5.1(side)")), "English - E-AC3 5.1")
        XCTAssertEqual(PhonePlayerMenuModel.audioHead(audio(2, "jpn", nil, "aac", "stereo")), "Japanese - AAC 2.0")
        XCTAssertEqual(PhonePlayerMenuModel.audioHead(audio(3, "eng", nil, nil, nil)), "English")
        XCTAssertEqual(PhonePlayerMenuModel.audioHead(audio(4, "und", "Director", "ac3", nil)), "Director")
        XCTAssertEqual(PhonePlayerMenuModel.audioHead(audio(5, nil, nil, nil, nil)), "Audio 5")
    }

    func testAudioRowAddsDefaultAndItsOwnName() {
        XCTAssertEqual(PhonePlayerMenuModel.audioRow(audio(1, "eng", "English", "eac3", "5.1", isDefault: true)), "English - E-AC3 5.1 (Default)")
        XCTAssertEqual(PhonePlayerMenuModel.audioRow(audio(5, "eng", "Commentary", "aac", "stereo")), "English - AAC 2.0 (Commentary)")
        XCTAssertEqual(PhonePlayerMenuModel.audioRow(audio(6, "fre", nil, "ac3", "5.1(side)")), "French - AC3 5.1")
    }

    func testAudioTitleIsTheTrackOn() {
        let tracks = [audio(1, "eng", "English", "eac3", "5.1"), audio(2, "jpn", nil, "aac", "stereo", selected: true)]
        XCTAssertEqual(PhonePlayerMenuModel.audioTitle(tracks), "Japanese - AAC 2.0")
        XCTAssertEqual(PhonePlayerMenuModel.audioTitle([]), "Audio")
    }

    // MARK: Subtitles

    func testSubtitleRows() {
        XCTAssertEqual(PhonePlayerMenuModel.subtitleRow(sub(3, "eng", "English", isDefault: true)), "English (Default)")
        XCTAssertEqual(PhonePlayerMenuModel.subtitleRow(sub(4, "spa", "Spanish")), "Spanish")
        XCTAssertEqual(PhonePlayerMenuModel.subtitleRow(sub(8, "eng", "English SDH", hearingImpaired: true)), "English (English SDH)")
        XCTAssertEqual(PhonePlayerMenuModel.subtitleRow(sub(9, "eng", "Signs & Songs", forced: true)), "English (Signs & Songs, Forced)")
        XCTAssertEqual(PhonePlayerMenuModel.subtitleRow(sub(10, "fre", nil, hearingImpaired: true)), "French (SDH)")
    }

    func testSubtitleTitleIsTheTrackOnOrNone() {
        XCTAssertEqual(PhonePlayerMenuModel.subtitleTitle([sub(3, "eng", "English"), sub(4, "spa", nil)]), "None")
        XCTAssertEqual(PhonePlayerMenuModel.subtitleTitle([sub(3, "eng", "English"), sub(4, "spa", nil, selected: true)]), "Spanish")
    }
}
