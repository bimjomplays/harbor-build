import AVFoundation
import CoreGraphics
import XCTest
@testable import HarborPhone

/// A source the tests drive: it records each request, can be slow, fail or hang until cancelled.
final class FakeScrubSource: ScrubFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [Double] = []
    private var _active = 0
    private var _maxActive = 0
    private var _parks = 0
    private var _closes = 0
    var delay: Double = 0.05
    var hang = false
    var fails: (Double) -> Bool = { _ in false }

    var requested: [Double] { lock.withLock { _requested } }
    var active: Int { lock.withLock { _active } }
    var maxActive: Int { lock.withLock { _maxActive } }
    var parks: Int { lock.withLock { _parks } }
    var closes: Int { lock.withLock { _closes } }

    func frame(at time: Double) async -> CGImage? {
        lock.withLock {
            _requested.append(time)
            _active += 1
            _maxActive = max(_maxActive, _active)
        }
        defer { lock.withLock { _active -= 1 } }
        if hang {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return nil
        }
        try? await Task.sleep(for: .seconds(delay))
        if Task.isCancelled || fails(time) { return nil }
        return ScrubTestImages.solid(width: 32, height: 18)
    }

    func park() { lock.withLock { _parks += 1 } }
    func close() { lock.withLock { _closes += 1 } }
}

enum ScrubTestImages {
    static func solid(width: Int, height: Int, rgb: (CGFloat, CGFloat, CGFloat) = (0.5, 0.5, 0.5)) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// The colour at the middle of `image` (0...255 each).
    static func centre(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.interpolationQuality = .none
            // Only the middle pixel lands in the 1×1 context.
            ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
}

/// The scrub preview's scheduler and cache (PhoneScrubPreview.swift): one decode at a time and always the
/// latest spot, frames kept per time bucket (bounded), failed spots left alone, the torrent rules
/// (rest before decoding, few tries, let go when the finger lifts).
@MainActor
final class PhoneScrubPreviewTests: XCTestCase {
    private let film: Double = 7200
    private let quick = ScrubPreviewConfig(timeout: 1, settle: 0, missFor: 30, missBudget: nil, giveUpAfter: nil,
                                           nearby: 0, idleClose: 30, parkOnEnd: false)

    private func until(_ timeout: Double = 3, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func preview(_ source: FakeScrubSource, _ config: ScrubPreviewConfig, key: String = "k") -> PhoneScrubPreview {
        let p = PhoneScrubPreview()
        p.prepare(key: key, duration: film, config: config, make: { source })
        return p
    }

    private func mid(_ time: Double) -> Double {
        PhoneScrubPreview.time(of: PhoneScrubPreview.bucket(time, duration: film), duration: film)
    }

    // MARK: buckets

    func testBucketSizeIsAFractionOfTheFilm() {
        XCTAssertEqual(PhoneScrubPreview.bucketSize(duration: 7200), 10)
        XCTAssertEqual(PhoneScrubPreview.bucketSize(duration: 2000), 5)
        XCTAssertEqual(PhoneScrubPreview.bucketSize(duration: 300), 2)
        XCTAssertEqual(PhoneScrubPreview.bucketSize(duration: 0), 5)
    }

    func testBucketAndItsTime() {
        XCTAssertEqual(PhoneScrubPreview.bucket(25, duration: 7200), 2)
        XCTAssertEqual(PhoneScrubPreview.bucket(-3, duration: 7200), 0)
        XCTAssertEqual(PhoneScrubPreview.time(of: 2, duration: 7200), 25)
        // Kept a second inside the end.
        XCTAssertEqual(PhoneScrubPreview.time(of: 719, duration: 7195), 7194)
    }

    // MARK: the cache

    func testCacheDropsTheLeastRecentlyUsedPastItsCount() {
        var cache = ScrubFrameCache(maxCount: 3, maxBytes: 1 << 30)
        for b in 0..<3 { cache.insert(ScrubTestImages.solid(width: 8, height: 8), bucket: b) }
        _ = cache.image(0)
        cache.insert(ScrubTestImages.solid(width: 8, height: 8), bucket: 3)
        XCTAssertEqual(cache.buckets, [0, 2, 3], "bucket 1 was the least recently used")
    }

    func testCacheStaysUnderItsBytes() {
        let image = ScrubTestImages.solid(width: 64, height: 36)
        let cost = ScrubFrameCache.cost(image)
        var cache = ScrubFrameCache(maxCount: 100, maxBytes: cost * 2)
        for b in 0..<5 { cache.insert(image, bucket: b) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.bytes, cost * 2)
        XCTAssertEqual(cache.buckets, [3, 4])
        // A frame bigger than the whole cache is not kept.
        cache.insert(ScrubTestImages.solid(width: 640, height: 360), bucket: 9)
        XCTAssertFalse(cache.contains(9))
        XCTAssertEqual(cache.bytes, cost * 2)
        // The same bucket again replaces its frame without counting it twice.
        cache.insert(image, bucket: 4)
        XCTAssertEqual(cache.bytes, cost * 2)
        cache.removeAll()
        XCTAssertEqual(cache.bytes, 0)
        XCTAssertEqual(cache.count, 0)
    }

    func testCacheNearest() {
        var cache = ScrubFrameCache()
        cache.insert(ScrubTestImages.solid(width: 4, height: 4), bucket: 10)
        cache.insert(ScrubTestImages.solid(width: 4, height: 4), bucket: 14)
        XCTAssertEqual(cache.nearest(to: 11, within: 4)?.bucket, 10)
        XCTAssertEqual(cache.nearest(to: 12, within: 4)?.bucket, 14, "a tie goes to the later frame")
        XCTAssertEqual(cache.nearest(to: 13, within: 4)?.bucket, 14)
        XCTAssertNil(cache.nearest(to: 20, within: 4))
        XCTAssertNil(cache.nearest(to: 11, within: -1))
    }

    // MARK: one decode, the latest spot

    func testOnlyTheLatestSpotDecodesNext() async {
        let source = FakeScrubSource()
        source.delay = 0.25
        let p = preview(source, quick)
        p.update(10)
        for t in stride(from: 100.0, through: 600, by: 100) {
            await settle(0.02)
            p.update(t)
        }
        await until { source.requested.count == 2 && p.image != nil }
        await settle(0.4)
        XCTAssertEqual(source.requested, [mid(10), mid(600)], "the moves while the first decoded only changed what came next")
        XCTAssertEqual(source.maxActive, 1, "never two decodes at once")
        XCTAssertNotNil(p.image)
        XCTAssertEqual(p.cache.buckets, [PhoneScrubPreview.bucket(10, duration: film), PhoneScrubPreview.bucket(600, duration: film)])
    }

    func testACachedBucketShowsWithoutDecoding() async {
        let source = FakeScrubSource()
        let p = preview(source, quick)
        p.update(10)
        await until { p.image != nil }
        p.update(nil)
        XCTAssertNil(p.image, "the frame goes when the finger lifts")
        p.update(13)
        XCTAssertNotNil(p.image, "same bucket: at once")
        await settle(0.15)
        XCTAssertEqual(p.decodesStarted, 1)
    }

    func testANearbyFrameStandsInWhileTheSpotDecodes() async {
        let source = FakeScrubSource()
        source.delay = 0.3
        var config = quick
        config.nearby = 45
        let p = preview(source, config)
        p.update(100)
        await until { p.image != nil }
        p.update(130)
        XCTAssertNotNil(p.image, "30 s away: the frame at 100 stands in")
        p.update(1000)
        XCTAssertNil(p.image, "far away: the time alone")
    }

    // MARK: failures

    func testATimeoutLeavesTheTimeAloneAndTheSpotAlone() async {
        let source = FakeScrubSource()
        source.hang = true
        var config = quick
        config.timeout = 0.1
        config.missFor = 0.3
        let p = preview(source, config)
        p.update(50)
        await until { source.requested.count == 1 && source.active == 0 }
        await settle(0.05)
        XCTAssertEqual(source.active, 0, "the timeout cancelled the decode")
        XCTAssertNil(p.image)
        p.update(nil)
        p.update(51)
        await settle(0.1)
        XCTAssertEqual(p.decodesStarted, 1, "a missed spot is not tried again at once")
        p.update(nil)
        await settle(0.3)
        p.update(52)
        await until { p.decodesStarted == 2 }
        XCTAssertEqual(p.decodesStarted, 2, "tried again once its miss ran out")
    }

    func testAMissBudgetPerDrag() async {
        let source = FakeScrubSource()
        source.fails = { _ in true }
        source.delay = 0.01
        var config = quick
        config.missBudget = 2
        let p = preview(source, config)
        for t in [100.0, 500, 900, 1300] {
            p.update(t)
            await settle(0.08)
        }
        XCTAssertEqual(p.decodesStarted, 2, "two misses spend the drag's tries")
        p.update(nil)
        p.update(2000)
        await until { p.decodesStarted == 3 }
        XCTAssertEqual(p.decodesStarted, 3, "a new drag has tries again")
    }

    func testGivesUpOnAStreamThatNeverGivesAFrame() async {
        let source = FakeScrubSource()
        source.fails = { _ in true }
        source.delay = 0.01
        var config = quick
        config.giveUpAfter = 2
        let p = preview(source, config)
        for t in [100.0, 500, 900] {
            p.update(t)
            await settle(0.08)
        }
        XCTAssertTrue(p.gaveUp)
        XCTAssertEqual(p.decodesStarted, 2)
        XCTAssertEqual(source.closes, 1)
        // Another stream starts over.
        p.prepare(key: "other", duration: film, config: config, make: { source })
        XCTAssertFalse(p.gaveUp)
    }

    // MARK: torrent rules

    func testSettleWaitsForTheFingerToRest() async {
        let source = FakeScrubSource()
        var config = quick
        config.settle = 0.15
        let p = preview(source, config)
        for t in [100.0, 200, 300, 400] {
            p.update(t)
            await settle(0.04)
        }
        XCTAssertEqual(source.requested.count, 0, "still moving: nothing decodes")
        await until { source.requested.count == 1 }
        await settle(0.1)
        XCTAssertEqual(source.requested, [mid(400)])
    }

    func testLiftingTheFingerStopsATorrentDecodeAndLetsTheStreamGo() async {
        let source = FakeScrubSource()
        source.hang = true
        var config = ScrubPreviewConfig.torrent
        config.settle = 0
        config.timeout = 5
        let p = preview(source, config)
        p.update(100)
        await until { source.active == 1 }
        p.update(nil)
        await until { source.active == 0 }
        XCTAssertEqual(source.active, 0, "the decode in flight was cancelled")
        XCTAssertGreaterThanOrEqual(source.parks, 1, "the stream was let go")
        source.hang = false
        p.update(100)
        await until { p.image != nil }
        XCTAssertNotNil(p.image, "a cancel is not a miss: the same spot decodes next time")
    }

    func testTheTorrentDefaultsAreCareful() {
        let t = ScrubPreviewConfig.torrent
        XCTAssertLessThanOrEqual(t.timeout, 2)
        XCTAssertGreaterThan(t.settle, 0)
        XCTAssertNotNil(t.missBudget)
        XCTAssertTrue(t.parkOnEnd)
        XCTAssertFalse(ScrubPreviewConfig.http.parkOnEnd)
    }

    // MARK: lifetime

    func testANewStreamStartsOver() async {
        let first = FakeScrubSource()
        let p = preview(first, quick)
        p.update(10)
        await until { p.image != nil }
        p.update(nil)
        // The same stream (a later duration report) keeps everything.
        p.prepare(key: "k", duration: film, config: quick, make: { FakeScrubSource() })
        XCTAssertEqual(p.cache.count, 1)
        let second = FakeScrubSource()
        p.prepare(key: "other", duration: film, config: quick, make: { second })
        XCTAssertEqual(first.closes, 1)
        XCTAssertEqual(p.cache.count, 0)
        p.update(10)
        await until { p.image != nil }
        XCTAssertEqual(second.requested.count, 1)
    }

    func testTheDecoderClosesWhenIdle() async {
        let source = FakeScrubSource()
        var config = quick
        config.idleClose = 0.1
        let p = preview(source, config)
        p.update(10)
        await until { p.image != nil }
        XCTAssertEqual(source.closes, 0)
        p.update(nil)
        await until { source.closes == 1 }
        XCTAssertEqual(source.closes, 1)
        XCTAssertEqual(p.cache.count, 1, "the frames stay")
    }

    func testTrimDropsTheFrames() async {
        let source = FakeScrubSource()
        let p = preview(source, quick)
        p.update(10)
        await until { p.image != nil }
        p.update(nil)
        p.trim()
        XCTAssertEqual(p.cache.count, 0)
        XCTAssertEqual(p.cache.bytes, 0)
    }

    func testCloseCancelsAndDropsALateFrame() async {
        let source = FakeScrubSource()
        source.delay = 0.2
        let p = preview(source, quick)
        p.update(10)
        await until { source.active == 1 }
        p.close()
        await settle(0.3)
        XCTAssertNil(p.image)
        XCTAssertEqual(p.cache.count, 0)
        XCTAssertEqual(source.closes, 1)
    }

    func testNoDurationNoPreview() {
        let source = FakeScrubSource()
        let p = PhoneScrubPreview()
        p.prepare(key: "k", duration: 0, config: quick, make: { source })
        p.update(10)
        XCTAssertNil(p.image)
        XCTAssertEqual(p.decodesStarted, 0)
    }

    // MARK: the pieces

    func testTimeoutCancelsTheSource() async {
        let source = FakeScrubSource()
        source.hang = true
        let start = Date()
        let image = await PhoneScrubPreview.frame(from: source, at: 5, timeout: 0.1)
        XCTAssertNil(image)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(source.active, 0)
    }

    func testOnceTakesTheFirstResultEvenBeforeItWaits() async {
        let once = ScrubOnce<Int>()
        once.resume(7)
        once.resume(9)
        let value = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in once.set(c) }
        XCTAssertEqual(value, 7)
    }

    func testFallbackMovesToTheSecondSourceAfterTwoMisses() async {
        let primary = FakeScrubSource()
        primary.fails = { _ in true }
        primary.delay = 0
        let secondary = FakeScrubSource()
        secondary.delay = 0
        let source = FallbackScrubFrameSource(primary: primary, secondary: { secondary })
        _ = await source.frame(at: 1)
        _ = await source.frame(at: 2)
        XCTAssertEqual(primary.closes, 1)
        let image = await source.frame(at: 3)
        XCTAssertNotNil(image)
        XCTAssertEqual(secondary.requested, [3])
        XCTAssertEqual(primary.requested, [1, 2])
    }

    func testFallbackKeepsAPrimaryThatHasWorked() async {
        var calls = 0
        let primary = FakeScrubSource()
        primary.delay = 0
        primary.fails = { _ in
            calls += 1
            return calls > 1
        }
        let secondary = FakeScrubSource()
        let source = FallbackScrubFrameSource(primary: primary, secondary: { secondary })
        for t in 1...4 { _ = await source.frame(at: Double(t)) }
        XCTAssertEqual(secondary.requested, [])
        XCTAssertEqual(primary.requested.count, 4)
    }

    func testOwnedFramesAreAtMost320Wide() {
        let big = ScrubTestImages.solid(width: 1920, height: 800)
        let small = ScrubFrames.owned(big)
        XCTAssertEqual(small?.width, 320)
        XCTAssertEqual(small?.height, 133)
        let tiny = ScrubFrames.owned(ScrubTestImages.solid(width: 100, height: 50))
        XCTAssertEqual(tiny?.width, 100)
    }

    func testPlateHeightKeepsTheFramesShape() {
        XCTAssertEqual(PhoneScrubPlate.frameHeight(ScrubTestImages.solid(width: 320, height: 180)), 90)
        XCTAssertEqual(PhoneScrubPlate.frameHeight(ScrubTestImages.solid(width: 320, height: 134)), 67)
        // Very wide or tall frames are kept between 2.4:1 and 4:3.
        XCTAssertEqual(PhoneScrubPlate.frameHeight(ScrubTestImages.solid(width: 400, height: 100)), 67)
        XCTAssertEqual(PhoneScrubPlate.frameHeight(ScrubTestImages.solid(width: 100, height: 400)), 120)
    }

    func testFixtureFramesDifferByTime() {
        let a = FixtureScrubFrameSource.render(time: 0, duration: 7200, still: nil)
        let b = FixtureScrubFrameSource.render(time: 3600, duration: 7200, still: nil)
        XCTAssertEqual(a?.width, 320)
        XCTAssertEqual(a?.height, 180)
        let ca = a.map(ScrubTestImages.centre)
        let cb = b.map(ScrubTestImages.centre)
        XCTAssertNotNil(ca)
        XCTAssertFalse(ca!.r == cb!.r && ca!.g == cb!.g && ca!.b == cb!.b)
    }

    func testPlanPicksTheDecoder() {
        let hash = String(repeating: "ab", count: 20)
        let torrent = URL(string: "http://127.0.0.1:8090/stream/\(hash)/0")!
        XCTAssertEqual(PhoneScrubPreview.plan(url: torrent, headers: [:], engine: .native, duration: 100).config, .torrent)
        XCTAssertTrue(PhoneScrubPreview.plan(url: torrent, headers: [:], engine: .native, duration: 100).make() is MPVScrubFrameSource)
        let file = URL(string: "https://example.com/film.mp4")!
        XCTAssertTrue(PhoneScrubPreview.plan(url: file, headers: [:], engine: .native, duration: 100).make() is FallbackScrubFrameSource)
        XCTAssertTrue(PhoneScrubPreview.plan(url: file, headers: [:], engine: .mpv, duration: 100).make() is MPVScrubFrameSource)
        XCTAssertEqual(PhoneScrubPreview.plan(url: file, headers: [:], engine: .mpv, duration: 100).config, .http)
        let hls = URL(string: "https://example.com/master.m3u8")!
        XCTAssertTrue(PhoneScrubPreview.plan(url: hls, headers: [:], engine: .native, duration: 100).make() is MPVScrubFrameSource)
        XCTAssertNotEqual(PhoneScrubPreview.plan(url: file, headers: [:], engine: .mpv, duration: 100).key,
                          PhoneScrubPreview.plan(url: file, headers: [:], engine: .native, duration: 100).key)
    }
}

/// The real decoders on a small H.264 film made here: 8 s, each second its own colour, a keyframe each
/// second.
final class PhoneScrubDecoderTests: XCTestCase {
    static let colours: [(CGFloat, CGFloat, CGFloat)] = [
        (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1), (0, 1, 1), (1, 1, 1), (0.5, 0.25, 0),
    ]
    private static var film: URL?

    private func makeFilm() async throws -> URL {
        if let film = Self.film, FileManager.default.fileExists(atPath: film.path) { return film }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrub-film-\(UUID().uuidString).mp4")
        let width = 640
        let height = 360
        let fps: Int32 = 10
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { throw XCTSkip("no AVAssetWriter here") }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: Int(fps), AVVideoAllowFrameReorderingKey: false] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw XCTSkip("the writer takes no H.264 input here") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("the writer did not start: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(Int(fps) * Self.colours.count) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw XCTSkip("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw XCTSkip("no pixel buffer") }
            let c = Self.colours[frame / Int(fps)]
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            ctx?.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw XCTSkip("the writer took no frame: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw XCTSkip("the writer did not finish: \(String(describing: writer.error))") }
        Self.film = url
        return url
    }

    /// The frame's middle is the colour of second `second` (each channel within a margin of the encoder's).
    private func assertColour(_ image: CGImage?, second: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let image else { return XCTFail("no frame", file: file, line: line) }
        XCTAssertLessThanOrEqual(image.width, ScrubFrames.maxWidth, file: file, line: line)
        let got = ScrubTestImages.centre(image)
        let want = Self.colours[second]
        let near = { (a: Int, b: CGFloat) in abs(a - Int(b * 255)) < 60 }
        XCTAssertTrue(near(got.r, want.0) && near(got.g, want.1) && near(got.b, want.2),
                      "second \(second): got \(got), wanted \(want)", file: file, line: line)
    }

    func testMPVTakesTheKeyframeBeforeTheSpot() async throws {
        let film = try await makeFilm()
        let source = MPVScrubFrameSource(url: film, headers: [:])
        defer { source.close() }
        // The first frame loads the file at the spot, the later ones seek.
        let first = await PhoneScrubPreview.frame(from: source, at: 2.5, timeout: 20)
        assertColour(first, second: 2)
        let second = await PhoneScrubPreview.frame(from: source, at: 5.5, timeout: 20)
        assertColour(second, second: 5)
        let back = await PhoneScrubPreview.frame(from: source, at: 1.5, timeout: 20)
        assertColour(back, second: 1)
        // After the stream was let go it opens again.
        source.park()
        let again = await PhoneScrubPreview.frame(from: source, at: 6.5, timeout: 20)
        assertColour(again, second: 6)
    }

    func testMPVAnswersACancelSoon() async throws {
        let film = try await makeFilm()
        let source = MPVScrubFrameSource(url: film, headers: [:])
        defer { source.close() }
        let start = Date()
        // A timeout shorter than any open: the wait ends at once and the next request still works.
        _ = await PhoneScrubPreview.frame(from: source, at: 3.5, timeout: 0.001)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let image = await PhoneScrubPreview.frame(from: source, at: 3.5, timeout: 20)
        assertColour(image, second: 3)
    }

    func testMPVGivesNilForAMissingFile() async {
        let source = MPVScrubFrameSource(url: URL(fileURLWithPath: "/nonexistent/film.mkv"), headers: [:])
        defer { source.close() }
        let image = await PhoneScrubPreview.frame(from: source, at: 3, timeout: 10)
        XCTAssertNil(image)
    }

    func testAVAssetImageGeneratorGivesSmallFrames() async throws {
        let film = try await makeFilm()
        let source = AVScrubFrameSource(url: film, headers: [:])
        let image = await PhoneScrubPreview.frame(from: source, at: 4.5, timeout: 20)
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(image?.width ?? .max, ScrubFrames.maxWidth)
    }
}
