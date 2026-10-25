import SwiftUI
import UIKit

/// Art from a url through the shared `ImageLoader` (downsampled to the size it is drawn at, cached
/// in memory and on disk). A grey plate until the picture arrives; nothing at all for a nil url.
struct PhoneImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// Where a fitted picture sits inside the frame (a logo that hugs the page's left margin).
    var alignment: Alignment = .center
    /// The grey plate under the art; off for a logo, which sits straight on the page.
    var plate = true
    /// The share of the drawn pixels to decode (1 = all). Art that is drawn under a heavy blur only needs a
    /// quarter of them: a full-screen backdrop at 3x is ~12 MB decoded, a quarter-size one under 1 MB.
    var decodeScale: CGFloat = 1
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if plate { BP.ink.opacity(0.07) }
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
                        .clipped()
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .task(id: loadKey(proxy.size)) {
                guard let url, let remote = URL(string: url) else {
                    image = nil
                    return
                }
                let scale = Double(max(1, displayScale)) * Double(min(1, max(0.05, decodeScale)))
                let target = ImageLoader.Target(width: max(1, clampedInt(Double(proxy.size.width) * scale)),
                                                height: max(1, clampedInt(Double(proxy.size.height) * scale)),
                                                fit: contentMode == .fit, capToSource: true)
                // Already decoded (a tile scrolled back into view): drawn at once, no plate and no fade.
                if let hit = ImageLoader.shared.cached(for: remote, target: target) {
                    image = hit
                    return
                }
                let loaded: UIImage? = await ImageLoader.shared.image(for: remote, target: target)
                guard !Task.isCancelled else { return }
                withMotion(.easeOut(duration: 0.2)) { image = loaded }
            }
        }
    }

    private func loadKey(_ size: CGSize) -> String {
        "\(url ?? "")|\(clampedInt(Double(size.width)))x\(clampedInt(Double(size.height)))"
    }
}

/// TMDB art sized for a phone screen.
enum PhoneArt {
    /// An episode still: the engine hands TMDB's `original` (often 1-3 MB of JPEG for a 148 pt thumbnail, a
    /// season of them on the title page); w780 is a size every TMDB still has and ~10x smaller. Any other
    /// url comes back unchanged.
    static func still(_ url: String?) -> String? {
        url?.replacingOccurrences(of: "image.tmdb.org/t/p/original/", with: "image.tmdb.org/t/p/w780/")
    }
}

/// The title written on the plate when a poster or backdrop has no picture to show.
private struct TitlePlate: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(PhoneTheme.display(15, .semibold, relativeTo: .subheadline))
            .foregroundStyle(BP.inkMuted)
            .multilineTextAlignment(.center)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    /// Settings → Appearance "Titles under posters" off (settings.hidePosterTitles): posters draw
    /// only their art (bp-tile.tsx showTitle).
    @Entry var phoneHidePosterTitles = false
}

/// A 2:3 poster with the title under it (unless Settings hides poster titles).
struct PosterTile: View {
    let meta: Meta
    var width: CGFloat = PhoneTheme.posterWidth
    var action: () -> Void = {}
    /// The art's zoom source id (PhoneZoomSource): the title page this tile opens zooms out of it.
    @State private var zoomKey = UUID().uuidString
    @Environment(\.phoneZoom) private var zoom
    @Environment(\.phoneHidePosterTitles) private var hideTitle
    @Environment(\.phoneRailScale) private var railScale

    var body: some View {
        let width: CGFloat = self.width * railScale
        Button {
            zoom?.arm(zoomKey)
            action()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    PhoneImage(url: meta.poster)
                    if meta.poster == nil { TitlePlate(title: meta.name) }
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
                .modifier(PhoneZoomSource(key: zoomKey))
                if !hideTitle {
                    Text(verbatim: meta.name)
                        .font(PhoneTheme.sans(13, .medium, relativeTo: .caption))
                        .foregroundStyle(BP.ink)
                        .lines(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: meta.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tile-\(meta.id)")
    }
}

/// A 16:9 backdrop card for Continue Watching: art, a progress bar along the bottom, a title and a
/// second line ("S2E4 · 34 min left").
struct BackdropTile: View {
    let title: String
    var subtitle: String? = nil
    var imageURL: String? = nil
    /// 0...1; nil draws no bar.
    var progress: Double? = nil
    var width: CGFloat = PhoneTheme.backdropWidth
    var identifier = ""
    var action: () -> Void = {}
    @Environment(\.phoneRailScale) private var railScale

    var body: some View {
        let width: CGFloat = self.width * railScale
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    PhoneImage(url: imageURL)
                    if imageURL == nil { TitlePlate(title: title) }
                    if let progress {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(BP.ink.opacity(0.25))
                                Capsule().fill(BP.accent).frame(width: proxy.size.width * CGFloat(min(max(progress, 0), 1)))
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
                Text(verbatim: title)
                    .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                        .foregroundStyle(BP.inkMuted)
                        .lines(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: subtitle.map { "\(title), \($0)" } ?? title))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier.isEmpty ? "backdrop-\(title)" : identifier)
    }
}

/// A titled horizontal rail of tiles. With `seeAll` the header carries a button (the row's "See all").
struct Rail<Content: View>: View {
    let title: String
    var seeAllTitle: String? = nil
    var seeAll: (() -> Void)? = nil
    /// Names the rail and its button for UI tests ("rail-<id>", "seeall-<id>"); the title when empty.
    var identifier = ""
    private let content: Content

    init(_ title: String, seeAllTitle: String? = nil, seeAll: (() -> Void)? = nil, identifier: String = "",
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.seeAllTitle = seeAllTitle
        self.seeAll = seeAll
        self.identifier = identifier
        self.content = content()
    }

    private var key: String { identifier.isEmpty ? title : identifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, actionTitle: seeAllTitle, action: seeAll, actionIdentifier: "seeall-\(key)")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: PhoneTheme.railGap) { content }
                    .padding(.horizontal, PhoneTheme.margin)
                    .phoneRailScaled()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rail-\(key)")
    }
}

/// The lead titles as full-width pages with dots under them; "Details" opens one.
struct HeroCarousel: View {
    let items: [Meta]
    let open: (Meta) -> Void
    @State private var current: String?

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { meta in
                        HeroCard(meta: meta, open: open)
                            .containerRelativeFrame(.horizontal)
                            .id(meta.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items) { meta in
                        Circle()
                            .fill(meta.id == (current ?? items.first?.id) ? BP.ink : BP.ink.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hero-carousel")
    }
}

private struct HeroCard: View {
    let meta: Meta
    let open: (Meta) -> Void

    private var detailLine: String {
        var parts: [String] = []
        if let year = meta.releaseInfo, !year.isEmpty { parts.append(year) }
        if let rating = meta.imdbRating, !rating.isEmpty { parts.append("★ \(rating)") }
        if let genres = meta.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhoneImage(url: meta.background ?? meta.poster)
            LinearGradient(colors: [.clear, BP.canvas.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: meta.name)
                    .font(PhoneTheme.display(32, .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                if !detailLine.isEmpty {
                    Text(verbatim: detailLine)
                        .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(BP.inkMuted)
                }
                Button { open(meta) } label: {
                    Label(T("Details"), systemImage: "info.circle")
                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("hero-details-\(meta.id)")
            }
            .padding(PhoneTheme.margin)
        }
        .frame(height: 400)
        .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous))
        .padding(.horizontal, PhoneTheme.margin)
    }
}

/// A profile's round face: its bundled avatar art on its colour (the catalog the TV draws, same paths),
/// else the first letter of its name on the colour.
struct ProfileFace: View {
    let name: String
    let colorHex: String
    var avatar: String? = nil
    var size: CGFloat = 72

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var art: UIImage? {
        guard let avatar, avatar.hasPrefix("/") else { return nil }
        return Self.bundledArt(avatar)
    }

    /// The avatars are small WebP files read from the bundle once, not on every redraw of a grid.
    private static let artCache = NSCache<NSString, UIImage>()

    static func bundledArt(_ path: String) -> UIImage? {
        if let hit = artCache.object(forKey: path as NSString) { return hit }
        let url = Bundle.main.bundleURL.appendingPathComponent(String(path.dropFirst()))
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        artCache.setObject(image, forKey: path as NSString)
        return image
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(css: colorHex) ?? BP.accent)
            if let art {
                Image(uiImage: art).resizable().scaledToFill()
            } else {
                Text(verbatim: initial)
                    .font(PhoneTheme.display(size * 0.42, .semibold, relativeTo: .title))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
