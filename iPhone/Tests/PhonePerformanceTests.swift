import XCTest
import UIKit
@testable import HarborPhone

/// The phone's image and memory budget: art is decoded no larger than it is drawn (and never
/// above its own pixels), a screenful of posters stays far under any memory limit, and the process footprint
/// has a generous ceiling. The numbers are wide on purpose: they catch a decode at the wrong size (a 10x
/// mistake), not a slow runner.
final class PhonePerformanceTests: XCTestCase {
    /// A gradient test picture as encoded JPEG bytes, `width` x `height` pixels.
    private func jpeg(_ width: Int, _ height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemOrange.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func pixels(_ image: UIImage?) -> (w: Int, h: Int) {
        guard let cg = image?.cgImage else { return (0, 0) }
        return (cg.width, cg.height)
    }

    /// The footprint the system charges this process, in bytes.
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // MARK: Decode size

    func testPosterDecodesNoLargerThanItIsDrawn() {
        // A 1500x2250 poster in a 330x495 px tile: the long edge is the tile's, not the file's.
        let image = ImageLoader.decode(jpeg(1500, 2250), target: .init(width: 330, height: 495, capToSource: true))
        let p = pixels(image)
        XCTAssertGreaterThan(p.h, 0)
        XCTAssertLessThanOrEqual(max(p.w, p.h), 500, "decoded \(p)")
    }

    func testSmallArtIsNeverDecodedAboveItsOwnPixels() {
        // A w780 backdrop (780x439) in a full-bleed hero (1179x1500 px): the cover scale would be 3.4x.
        let image = ImageLoader.decode(jpeg(780, 439), target: .init(width: 1179, height: 1500, capToSource: true))
        let p = pixels(image)
        XCTAssertGreaterThan(p.w, 0)
        XCTAssertLessThanOrEqual(max(p.w, p.h), 780, "decoded \(p)")
    }

    func testTheTVsDecodeIsUnchangedWithoutTheCap() {
        // Without capToSource nothing may exceed the loader's own ceilings (what the TV relies on).
        let p = pixels(ImageLoader.decode(jpeg(780, 439), target: .init(width: 1179, height: 1500)))
        XCTAssertGreaterThan(p.w, 0)
        XCTAssertLessThanOrEqual(max(p.w, p.h), ImageLoader.sizedMaxPixel)
    }

    func testBlurredArtDecodesFarSmaller() {
        // A 4K backdrop behind a blur on a full screen: at the screen's pixels it covers the box (the long
        // edge reaches the loader's 3840 cap); at a quarter of them it is ~1100 px.
        let data = jpeg(4000, 2250)
        let full = pixels(ImageLoader.decode(data, target: .init(width: 1179, height: 2556, capToSource: true)))
        let quarter = pixels(ImageLoader.decode(data, target: .init(width: 295, height: 639, capToSource: true)))
        XCTAssertGreaterThan(full.w * full.h, 0)
        XCTAssertLessThan(quarter.w * quarter.h * 4, full.w * full.h, "full \(full), quarter \(quarter)")
    }

    func testEpisodeStillsDropTMDBOriginal() {
        XCTAssertEqual(PhoneArt.still("https://image.tmdb.org/t/p/original/abc.jpg"), "https://image.tmdb.org/t/p/w780/abc.jpg")
        XCTAssertEqual(PhoneArt.still("https://image.tmdb.org/t/p/w300/abc.jpg"), "https://image.tmdb.org/t/p/w300/abc.jpg")
        XCTAssertEqual(PhoneArt.still("https://episodes.metahub.space/tt1/1/1/w780.jpg"), "https://episodes.metahub.space/tt1/1/1/w780.jpg")
        XCTAssertNil(PhoneArt.still(nil))
    }

    func testHeroBackdropAsksForW1280() {
        XCTAssertEqual(PhoneArt.backdrop("https://image.tmdb.org/t/p/w780/abc.jpg"), "https://image.tmdb.org/t/p/w1280/abc.jpg")
        XCTAssertEqual(PhoneArt.backdrop("https://image.tmdb.org/t/p/original/abc.jpg"), "https://image.tmdb.org/t/p/original/abc.jpg")
        XCTAssertEqual(PhoneArt.backdrop("https://images.metahub.space/background/medium/tt1/img"), "https://images.metahub.space/background/medium/tt1/img")
        XCTAssertNil(PhoneArt.backdrop(nil))
    }

    // MARK: Memory

    /// Decodes 200 posters the way a long Library grid does and keeps them all alive: at drawn size that is
    /// ~130 MB at most, a full-size decode would be ~2 GB. The ceilings are 3x the expected, so only a
    /// decode at the wrong size can trip them.
    func testAScreenfulOfPostersStaysUnderTheMemoryCeiling() {
        let data = jpeg(1000, 1500)
        let before = footprint()
        var kept: [UIImage] = []
        for _ in 0..<200 {
            if let image = ImageLoader.decode(data, target: .init(width: 330, height: 495, capToSource: true)) { kept.append(image) }
        }
        XCTAssertEqual(kept.count, 200)
        let bytes = kept.reduce(0) { $0 + (($1.cgImage?.bytesPerRow ?? 0) * ($1.cgImage?.height ?? 0)) }
        XCTAssertLessThan(bytes, 200 * 330 * 495 * 4 * 3 / 2, "decoded bitmaps total \(bytes) bytes")
        let grown = footprint() - before
        XCTAssertLessThan(grown, 600 << 20, "the footprint grew \(grown >> 20) MB for 200 posters")
        XCTAssertLessThan(footprint(), 1500 << 20, "the process footprint is \(footprint() >> 20) MB")
    }

    /// How long one poster takes from bytes to bitmap (a clock metric: recorded in the result bundle, not
    /// compared with a baseline, so a slow runner cannot fail it).
    func testPosterDecodeTime() {
        let data = jpeg(1000, 1500)
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<20 { _ = ImageLoader.decode(data, target: .init(width: 330, height: 495, capToSource: true)) }
        }
    }

    // MARK: App icon

    /// The AppIcon set (light, dark and tinted variants) compiled into the app: the bundle names it.
    func testAppIconSetIsCompiledIn() {
        let info = Bundle.main.infoDictionary ?? [:]
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let name = (info["CFBundleIconName"] as? String) ?? (primary?["CFBundleIconName"] as? String)
        XCTAssertEqual(name, "AppIcon", "Info.plist icons: \(String(describing: icons))")
    }
}
