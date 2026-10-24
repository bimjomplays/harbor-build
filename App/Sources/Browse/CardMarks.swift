import Foundation
import Combine
import SwiftUI


/// The overlay every tile draws (bp-card-state-marks.tsx geometry: 7 px insets, 5 px gaps,
/// 26 px circles, ribbon 27 % of the card width flush with the top edge).
struct CardMarksOverlay: View {
    let marks: CardMarks?
    /// Local fallback for screenshot fixtures and the moment before the engine answers.
    let fallbackChip: String?
    let size: CGSize
    /// The Top 10 ribbon (off on a rank cell, whose numeral says it).
    var ribbon: Bool = true

    private var chip: String? { marks?.chip ?? fallbackChip }

    var body: some View {
        ZStack(alignment: .topLeading) {
            corner(.topLeading) {
                if let chip { chipView(chip) }
                if marks?.bookmark == "topStart" { circle("bookmark.fill") }
            }
            corner(.topTrailing) {
                if marks?.bookmark == "topEnd" { circle("bookmark.fill") }
                if marks?.watched == "topEnd" { circle("checkmark") }
            }
            corner(.bottomTrailing) {
                // Upstream's bottom-anchored column puts the bookmark nearest the corner.
                if marks?.watched == "bottomEnd" { circle("checkmark") }
                if marks?.bookmark == "bottomEnd" { circle("bookmark.fill") }
            }
            corner(.bottomLeading) {
                if marks?.bookmark == "bottomStart" { circle("bookmark.fill") }
            }
            if ribbon, let side = marks?.top10, let tab = Self.ribbon(side: side) {
                // bp-card-marks.tsx: no aria-label of its own upstream either; the tile that hosts
                // this overlay already speaks its own name (and, where it applies, its marks).
                Image(uiImage: tab)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: min(max(size.width * 0.27, BP.px(34)), BP.px(72)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == "left" ? .topLeading : .topTrailing)
                    .padding(.horizontal, BP.px(7))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func corner<C: View>(_ alignment: Alignment, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: alignment.horizontal == .leading ? .leading : .trailing, spacing: BP.px(5)) { content() }
            .padding(BP.px(7))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// A bright white chip on nearly every poster ("NEW") read as
    /// noise over the art. The chip is a quiet dark glass label now; an award reads in gold.
    private func chipView(_ text: String) -> some View {
        let up: String = text.uppercased()
        let award: Bool = ["OSCAR", "EMMY", "BAFTA", "GLOBE", "WINNER", "CANNES", "PALME", "AWARD"].contains { up.contains($0) }
        return Text(text)
            .font(BP.sans(9.8, .bold)).textCase(.uppercase).tracking(0.5).lineLimit(1)
            .foregroundStyle(award ? Color(red: 0.96, green: 0.80, blue: 0.40) : Color.white)
            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(3))
            .background(RoundedRectangle(cornerRadius: BP.px(4), style: .continuous).fill(Color.black.opacity(0.62)))
            .overlay(RoundedRectangle(cornerRadius: BP.px(4), style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .frame(maxWidth: size.width - BP.px(56), alignment: .leading)
    }

    // bp-card-state-marks.tsx BpStateCircle aria-label={label}: the glyph itself carries no name;
    // the tile that hosts this overlay already speaks "Watched" / "In watchlist" in its own value.
    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: BP.px(11), weight: .heavy))
            .foregroundStyle(BP.ink)
            .frame(width: BP.px(26), height: BP.px(26))
            .background(Circle().fill(BP.void_.opacity(0.92)))
            .overlay(Circle().strokeBorder(BP.edge2, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private static var cache: [String: UIImage] = [:]
    static func ribbon(side: String) -> UIImage? {
        let name = side == "left" ? "toptabl" : "toptabr"
        if let hit = cache[name] { return hit }
        guard let path = Bundle.main.path(forResource: name, ofType: "png", inDirectory: "marks"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        cache[name] = img
        return img
    }
}
