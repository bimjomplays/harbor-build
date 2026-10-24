import SwiftUI
import UIKit

/// index.css `[data-kids="on"]`: the light sea palette every kids surface paints with, plus the
/// literal colours the kids views use (kids.tsx, kids-detail.tsx, play-zone.tsx).
enum KidsTheme {
    static let canvas = Color(hex: 0xb6dee4)
    static let surface = Color(hex: 0xc6e8ed)
    static let elevated = Color(hex: 0xd6f0f3)
    static let raised = Color(hex: 0xe9f7f9)
    /// oklch(0.4 0.07 205), oklch(0.52 0.06 205), oklch(0.63 0.045 205) in sRGB.
    static let ink = Color(hex: 0x00525a)
    static let inkMuted = Color(hex: 0x3b7379)
    static let inkSubtle = Color(hex: 0x699196)
    /// `text-[#0e3a43]`: row titles, chips, episode names.
    static let deep = Color(hex: 0x0e3a43)
    /// `bg-[#1f8f88]`: the kids Play button and the chosen season.
    static let teal = Color(hex: 0x1f8f88)
    /// `bg-[#ffd166]` / `text-[#4a3200]`: "Let's play!", "Another one!", the active filter.
    static let sunny = Color(hex: 0xffd166)
    static let sunnyInk = Color(hex: 0x4a3200)
    /// Play Zone copy on white cards.
    static let sea = Color(hex: 0x123a52)
    static let seaMuted = Color(hex: 0x3c6a84)
    /// `[data-kids="on"] [data-harbor-sidebar]`: the kids chrome background.
    static let bar = Color(hex: 0xe5f5f5)
    /// `.harbor-mark-sail` / `.harbor-mark-hull` under kids.
    static let sail = Color(hex: 0x6bc5ca)

    /// Upstream sets kids type in "Fredoka", "Baloo 2"; SF Rounded is the nearest face on tvOS.
    static func font(_ px: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: BP.px(px), weight: weight, design: .rounded)
    }

    /// The kids card shadow (`shadow-[0_16px_40px_-14px_rgba(20,40,60,0.45)]`).
    static let shadow = Color(red: 20 / 255, green: 40 / 255, blue: 60 / 255)

    private static let cache = NSCache<NSString, UIImage>()

    /// Upstream's `/kids/...` public art, bundled from App/Upstream/kids by
    /// tools/sync_upstream_assets.sh (the folder lands at the bundle root as `kids/`).
    static func art(_ path: String) -> UIImage? {
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let hit = cache.object(forKey: rel as NSString) { return hit }
        let url = Bundle.main.bundleURL.appendingPathComponent(rel)
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: rel as NSString)
        return img
    }

    /// A memory warning: let go of the cached art (kidsbg.png alone is 2608 × 1600,
    /// ~17 MB once drawn). Art on screen stays drawn; the next read comes from the bundle again.
    static func purgeArt() {
        cache.removeAllObjects()
    }

    /// `/kids/doodles/<name>.png`.
    static func doodle(_ name: String) -> UIImage? { art("/kids/doodles/\(name).png") }
}
