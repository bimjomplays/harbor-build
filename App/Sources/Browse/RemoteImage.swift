import SwiftUI
import UIKit
import ImageIO


/// lib/img-size.ts for poster cards (components/poster.tsx): a TMDB image is asked for at the
/// smallest tier that covers the card at the screen's scale (capped at 2, as poster.tsx caps
/// devicePixelRatio) times qualityMultiplier(settings.posterQuality); "max" keeps the URL as the
/// catalog gave it. Google and Deezer artwork sizes are rewritten the same way (upgradeArtworkUrl).
enum PosterSizing {
    private static let tmdbTiers = [92, 154, 185, 300, 342, 500, 780, 1280]

    /// img-size.ts qualityMultiplier: max → 0 (no resizing), high → 1.5, balanced → 1.
    static func multiplier(_ quality: String?) -> Double {
        switch quality ?? "high" {
        case "max": return 0
        case "high": return 1.5
        default: return 1
        }
    }

    static func sized(_ url: String?, width: CGFloat, scale: CGFloat, quality: String?) -> String? {
        guard let url, !url.isEmpty else { return url }
        // jikan.ts bestPoster, kitsu.ts pickPoster and anilist/to-meta.ts anilistMediaToMeta each bake
        // a fixed, small-web-card file into every anime poster no matter how big the caller's tile is
        // (MAL: MAL_CARD_WANT 266 never exceeds MAL_SMALL_MAX 300, so it is always image_url, ~225x319,
        // even reused as the hero backdrop; Kitsu: pickPoster tries medium, ~390x554, before large or
        // original; AniList: coverImage.large before .extraLarge). None of those three take a width, so
        // "quality" and tile size cannot help the way they do for a TMDB tier; upgrade them unconditionally
        // to the biggest fixed file the same CDN already serves at a sibling path, before the quality gate.
        let upgraded = upgradeFixedTierArt(url)
        let mult = multiplier(quality)
        guard mult > 0, width > 0 else { return upgraded }
        let target = Int((Double(width) * Double(min(2, max(1, scale))) * mult).rounded(.up))
        return sizeImageUrl(upgraded, target)
    }

    /// img-size.ts sizeImageUrl.
    static func sizeImageUrl(_ url: String, _ targetPx: Int) -> String {
        guard targetPx > 0 else { return url }
        let seg = tmdbTiers.first { $0 >= targetPx }.map { "w\($0)" } ?? "original"
        // This runs in every poster tile's body (each marks refresh redraws every tile
        // on screen). The regex searches only run when the literal part they need is there: a
        // Cinemeta/metahub poster went through two failing regex searches per tile per redraw.
        if url.contains("/t/p/"), let r = url.range(of: #"/t/p/(w\d+|original)/"#, options: .regularExpression) {
            let sized = url.replacingCharacters(in: r, with: "/t/p/\(seg)/")
            if sized != url { return sized }
        }
        return upgradeArtworkUrl(url, targetPx)
    }

    /// img-size.ts upgradeArtworkUrl: Google (=wN-hN, up to 1200) and Deezer (/NxN-, up to 1000) art.
    static func upgradeArtworkUrl(_ url: String, _ targetPx: Int) -> String {
        if url.contains("=w"), let r = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            let size = min(1200, max(targetPx, 1))
            return url.replacingCharacters(in: r, with: "=w\(size)-h\(size)")
        }
        if url.contains("dzcdn.net"), let r = url.range(of: #"/\d+x\d+-"#, options: .regularExpression) {
            let size = min(1000, max(targetPx, 1))
            return url.replacingCharacters(in: r, with: "/\(size)x\(size)-")
        }
        return url
    }

    /// The three anime image hosts upstream's own providers under-ask by design (a small web card
    /// never needs more): each serves a bigger file of the very same picture at a sibling path, so
    /// unlike TMDB/Google/Deezer this needs no target size, only the file that was already picked.
    static func upgradeFixedTierArt(_ url: String) -> String {
        // jikan.ts JikanAnime.images: cdn.myanimelist.net/images/anime/{a}/{id}.jpg is the ~225x319
        // "image_url" default (or ".../{id}t.jpg", the ~100x140 search thumbnail); ".../{id}l.jpg" is
        // MAL's own ~318x449 "large_image_url" at the same path. A digit right before the extension
        // means neither suffix is present yet; skip anything already ending in a letter (l or t).
        if url.contains("cdn.myanimelist.net"),
           let r = url.range(of: #"\d+\.jpe?g$"#, options: .regularExpression),
           let dot = url[r].lastIndex(of: ".") {
            var out = url
            out.insert("l", at: dot)
            return out
        }
        // kitsu.ts pickPoster: media.kitsu.{io,app}/anime/poster_images/{id}/{tiny|small|medium}.ext;
        // "large" (the biggest kitsu ever gives a posterImage, kitsu.ts never asks for "original")
        // sits at the same path with the size word swapped.
        if url.contains("/poster_images/"),
           let r = url.range(of: #"/(tiny|small|medium)\.\w+$"#, options: .regularExpression),
           let dot = url[r].firstIndex(of: ".") {
            return url.replacingCharacters(in: r, with: "/large\(url[dot...])")
        }
        // anilist/to-meta.ts, franchise-root.ts, browse.ts: coverImage.large before .extraLarge, but
        // AniList's own "large" GraphQL field is the CDN's `/cover/medium/` file and "extraLarge" is
        // `/cover/large/`, the biggest AniList serves; s4.anilist.co never uses "extralarge" in a path.
        if url.contains("s4.anilist.co"),
           let r = url.range(of: #"/cover/(small|medium)/"#, options: .regularExpression) {
            return url.replacingCharacters(in: r, with: "/cover/large/")
        }
        return url
    }
}

/// Art with upstream's loading plate; fades in when the bytes arrive.
/// The plate measures itself and asks for the image at that size (ImageLoader.Target).
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// components/poster.tsx usePosterChain onError: when `url` cannot be
    /// loaded, the next candidate (the plain poster behind an RPDB / poster-service url) is shown.
    var fallback: String? = nil
    /// Told the url and whether anything drew (false: neither `url` nor `fallback`
    /// loaded), so a tile can print its title plate the way bp-tile does once its art chain runs out.
    var onResult: ((String, Bool) -> Void)? = nil
    /// Where a fitted picture sits in its box (a title logo hugs the leading edge).
    var alignment: Alignment = .center
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var box: CGSize = .zero
    @State private var shownURL: String?

    private struct LoadKey: Hashable { var url: String?; var fallback: String?; var width: Int; var height: Int }

    /// The box in pixels, rounded up to 64 px steps so small layout changes reuse the cached decode.
    private var loadKey: LoadKey {
        let scale = Double(max(1, displayScale))
        func px(_ v: CGFloat) -> Int {
            let d = Double(v) * scale
            guard d.isFinite, d > 0 else { return 0 }
            return (Int(min(d, 16_384)) / 64 + 1) * 64
        }
        return LoadKey(url: url, fallback: fallback, width: px(box.width), height: px(box.height))
    }

    var body: some View {
        ZStack(alignment: alignment) {
            // The plate only while nothing is loaded: drawn under the picture it showed through
            // transparent art (a title logo on Detail sat in a grey box).
            if image == nil { BP.ink.opacity(0.07) }
            if let image {
                // Art is decoration: VoiceOver said "image" on every poster and
                // backdrop. A caller that names the picture wraps it in its own labelled element.
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { box = g.size }
                .onChange(of: g.size) { _, size in box = size }
        })
        .task(id: loadKey) {
            let key = loadKey
            // A new URL clears the old art; a new size keeps it up until the sharper decode lands.
            if shownURL != key.url { image = nil; failed = false; shownURL = key.url }
            // Nothing is asked for until the plate has a size (the first layout pass sets it).
            guard let url = key.url, key.width > 0, key.height > 0 else { return }
            let target = ImageLoader.Target(width: key.width, height: key.height, fit: contentMode == .fit)
            // A primary that cannot be a URL (a poster template or key with a stray
            // character) went straight to the empty plate without trying the fallback; one that
            // already failed with its fallback loading is skipped (ImageLoader.deadPrimaries).
            var dead = false
            if key.fallback != nil { dead = await ImageLoader.shared.isDead(url) }
            var img: UIImage?
            if !dead, let u = URL(string: url) { img = await ImageLoader.shared.image(for: u, target: target) }
            guard !Task.isCancelled else { return }
            if img == nil, let next = key.fallback, next != url, let nu = URL(string: next) {
                img = await ImageLoader.shared.image(for: nu, target: target)
                guard !Task.isCancelled else { return }
                if img != nil, !dead { await ImageLoader.shared.markDead(url) }
            }
            if image == nil { withAnimation(BP.easeFast) { image = img } } else if let img { image = img }
            failed = img == nil
            onResult?(url, img != nil)
        }
    }
}
