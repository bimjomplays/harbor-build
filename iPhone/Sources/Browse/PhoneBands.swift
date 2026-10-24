import SwiftUI

/// The shapes the TV's bands use besides a plain poster (BrowseRow.shape): Top 10 with its rank
/// numeral, a streaming service or addon as a brand tile, and a curated collection as a 16:9 card.

/// A Top 10 cell: the rank numeral standing behind the left edge of the poster.
struct RankTile: View {
    let meta: Meta
    let rank: Int
    var width: CGFloat = PhoneTheme.posterWidth
    var action: () -> Void = {}

    /// The poster's zoom source id (PhoneZoomSource), as on PosterTile.
    @State private var zoomKey = UUID().uuidString
    @Environment(\.phoneZoom) private var zoom
    @Environment(\.phoneRailScale) private var railScale

    private var numeralWidth: CGFloat { scaled * 0.42 }
    private var scaled: CGFloat { width * railScale }

    var body: some View {
        let width: CGFloat = scaled
        Button {
            zoom?.arm(zoomKey)
            action()
        } label: {
            HStack(alignment: .bottom, spacing: -numeralWidth * 0.18) {
                Text(verbatim: "\(rank)")
                    .font(PhoneTheme.display(width * 0.95, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(BP.ink.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: numeralWidth, alignment: .trailing)
                    .padding(.bottom, -width * 0.06)
                    .accessibilityHidden(true)
                ZStack {
                    PhoneImage(url: meta.poster ?? meta.background)
                    if meta.poster == nil && meta.background == nil {
                        Text(verbatim: meta.name)
                            .font(PhoneTheme.sans(13, .semibold, relativeTo: .caption))
                            .foregroundStyle(BP.inkMuted)
                            .multilineTextAlignment(.center)
                            .padding(8)
                    }
                }
                .frame(width: width * 0.72, height: width * 1.08)
                .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
                .modifier(PhoneZoomSource(key: zoomKey))
            }
            .frame(width: width * 0.72 + numeralWidth * 0.82, alignment: .leading)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(rank), \(meta.name)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tile-\(meta.id)")
    }
}

/// A streaming service or an installed addon: its tint over the panel, its logo (addons) over its name.
struct BrandTile: View {
    let meta: Meta
    var width: CGFloat = 132
    var action: () -> Void = {}
    @Environment(\.phoneRailScale) private var railScale

    private var tint: Color { Color(css: meta.providerBadge?.tint ?? "") ?? BP.ink }
    private var whiteMark: Bool { (meta.providerBadge?.tint ?? "").uppercased() == "#FFFFFF" }
    private var logo: String? {
        guard let url = meta.providerBadge?.logo, !url.isEmpty else { return nil }
        return url
    }

    var body: some View {
        let width: CGFloat = self.width * railScale
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.panel)
                RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous)
                    .fill(tint.opacity(whiteMark ? 0.18 : 0.62))
                LinearGradient(colors: [BP.ink.opacity(0.12), .clear, BP.void_.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
                if let logo {
                    VStack(spacing: 6) {
                        PhoneImage(url: logo, contentMode: .fit, plate: false)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(verbatim: meta.name)
                            .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(BP.ink)
                            .lines(1)
                            .padding(.horizontal, 8)
                    }
                } else {
                    Text(verbatim: meta.name)
                        .font(PhoneTheme.display(17, .semibold, relativeTo: .headline))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                        .multilineTextAlignment(.center)
                        .padding(10)
                }
            }
            .frame(width: width, height: width * 0.64)
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: meta.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tile-\(meta.id)")
    }
}

/// A curated collection: its backdrop under a scrim, the meta line ("3 films") over the name. The
/// line rides in `description`, as the TV's collection card reads it.
struct CollectionTile: View {
    let meta: Meta
    var width: CGFloat = 200
    var action: () -> Void = {}
    @Environment(\.phoneRailScale) private var railScale

    var body: some View {
        let width: CGFloat = self.width * railScale
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.panel)
                if let background = meta.background, !background.isEmpty {
                    PhoneImage(url: background).opacity(0.85)
                }
                LinearGradient(stops: [.init(color: BP.void_.opacity(0.92), location: 0),
                                       .init(color: BP.void_.opacity(0.44), location: 0.54),
                                       .init(color: .clear, location: 1)],
                               startPoint: .bottom, endPoint: .top)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: meta.description ?? T("Collection"))
                        .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(BP.inkSubtle)
                        .lines(1)
                    Text(verbatim: meta.name)
                        .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(10)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: meta.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tile-\(meta.id)")
    }
}

extension PhoneRoute {
    /// Where a band tile goes: services, addons and collections have a page of their own (a stub
    /// until their stage); nil for an ordinary title, which opens the title page.
    init?(band meta: Meta) {
        if meta.id.hasPrefix("service:") {
            self = .service(id: String(meta.id.dropFirst(8)), name: meta.name)
        } else if meta.id.hasPrefix("addon:") {
            self = .addon(base: String(meta.id.dropFirst(6)), name: meta.name, logo: meta.providerBadge?.logo)
        } else if meta.id.hasPrefix("collection:tmdb:") {
            self = .collection(ref: String(meta.id.dropFirst(16)), name: meta.name, image: meta.background)
        } else {
            return nil
        }
    }
}
