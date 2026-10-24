import SwiftUI
import UIKit
import CoreImage

/// Softened hero art, cached per URL (and dropped on a memory warning).
final class HeroBlur: @unchecked Sendable {
    static let shared = HeroBlur()
    private let cache = NSCache<NSString, UIImage>()
    private let context = CIContext(options: [.cacheIntermediates: false])

    init() {
        cache.countLimit = 48
    }

    /// A memory warning drops the blurred bitmaps (the one on screen stays drawn).
    func purge() {
        cache.removeAllObjects()
    }

    /// A hero art file under ~1100 px wide (an anime episode
    /// still, a small fixed-tier poster) is stretched ~3-6x across the 4K screen and shows its JPEG
    /// blocks. It is drawn through a light Gaussian soften instead: the picture still reads, the
    /// blocks do not. Bigger art is returned as is.
    func softenIfSmall(_ image: UIImage, key: String) async -> UIImage {
        let px: CGFloat = image.size.width * image.scale
        guard px > 0, px < 1100 else { return image }
        let cacheKey: NSString = ("soft:" + key) as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        let out: UIImage? = await Task.detached(priority: .userInitiated) { [self] in
            self.soften(image)
        }.value
        guard let out else { return image }
        cache.setObject(out, forKey: cacheKey)
        return out
    }

    private func soften(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage, cg.width > 0 else { return nil }
        let input = CIImage(cgImage: cg)
        let sigma: Double = max(1.2, Double(cg.width) / 520)
        let softened = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let out = context.createCGImage(softened, from: input.extent) else { return nil }
        return UIImage(cgImage: out)
    }
}
