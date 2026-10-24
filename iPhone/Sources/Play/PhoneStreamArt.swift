import SwiftUI
import UIKit

// The play picker's art: the stream rows' format badges (badges/ folder)
// and audio-language flags (Flags.xcassets), both from tools/sync_upstream_assets.sh, as the Apple
// TV's StreamBadgeArt and FlagStack draw them (App/Sources/Streams, a TV-only folder), at phone sizes.

/// components/flag.tsx's language → flag tables, a copy of the TV's FlagArt (engine/smoke.mjs
/// checks the two copies match, so keep one entry per line).
@MainActor
enum PhoneFlagArt {
    /// flag.tsx FLAG: the languages drawn with upstream's own art (src/assets/flags/*.svg), which
    /// tools/sync_upstream_assets.sh turns into vector imagesets in App/Upstream/Flags.xcassets.
    static let file: [String: String] = [
        "English": "flag-eng",
        "Italian": "flag-ita",
        "Russian": "flag-rus",
        "Hindi": "flag-hin",
        "Spanish": "flag-spa",
        "Spanish (Latin America)": "flag-spa",
        "Korean": "flag-kor",
        "Japanese": "flag-jpn",
        "Chinese": "flag-zho",
        "Chinese (Simplified)": "flag-zho",
        "Portuguese": "flag-prt",
        "Portuguese (Brazil)": "flag-bra",
        "German": "flag-deu",
        "French": "flag-fra",
        "Turkish": "flag-tur",
        "Arabic": "flag-ara",
        "Czech": "flag-ces",
        "Danish": "flag-dan",
        "Finnish": "flag-fin",
        "Hebrew": "flag-heb",
        "Hungarian": "flag-hun",
        "Dutch": "flag-nld",
        "Norwegian": "flag-nor",
        "Polish": "flag-pol",
        "Romanian": "flag-ron",
        "Swedish": "flag-swe",
        "Thai": "flag-tha",
        "Ukrainian": "flag-ukr",
        "Vietnamese": "flag-vie",
    ]

    /// flag.tsx LANG_COUNTRY: the languages upstream draws from the flag-icons set (`fi fi-{cc}`).
    /// That set is an npm package neither Apple build installs, so these are drawn as the
    /// country's emoji flag (Apple Color Emoji); a region with no emoji flag gets the text chip.
    static let country: [String: String] = [
        "Indonesian": "id",
        "Greek": "gr",
        "Tamil": "in",
        "Telugu": "in",
        "Malayalam": "in",
        "Kannada": "in",
        "Bengali": "bd",
        "Marathi": "in",
        "Gujarati": "in",
        "Punjabi": "in",
        "Urdu": "pk",
        "Odia": "in",
        "Assamese": "in",
        "Nepali": "np",
        "Sinhala": "lk",
        "Malay": "my",
        "Filipino": "ph",
        "Burmese": "mm",
        "Khmer": "kh",
        "Lao": "la",
        "Persian": "ir",
        "Pashto": "af",
        "Azerbaijani": "az",
        "Georgian": "ge",
        "Armenian": "am",
        "Kazakh": "kz",
        "Uzbek": "uz",
        "Bulgarian": "bg",
        "Serbian": "rs",
        "Croatian": "hr",
        "Bosnian": "ba",
        "Slovak": "sk",
        "Slovenian": "si",
        "Lithuanian": "lt",
        "Latvian": "lv",
        "Estonian": "ee",
        "Icelandic": "is",
        "Irish": "ie",
        "Catalan": "es-ct",
        "Basque": "es-pv",
        "Galician": "es-ga",
        "Welsh": "gb-wls",
        "Maltese": "mt",
        "Albanian": "al",
        "Macedonian": "mk",
        "Belarusian": "by",
        "Swahili": "tz",
        "Amharic": "et",
        "Afrikaans": "za",
        "Hausa": "ng",
        "Yoruba": "ng",
        "Igbo": "ng",
        "Zulu": "za",
    ]

    /// The country each upstream flag file draws, for its emoji twin when the imageset is missing
    /// (a build that skipped the sync step). flag-eng is the US flag, flag-ara Saudi Arabia's.
    private static let fileCountry: [String: String] = [
        "flag-eng": "us", "flag-ita": "it", "flag-rus": "ru", "flag-hin": "in", "flag-spa": "es",
        "flag-kor": "kr", "flag-jpn": "jp", "flag-zho": "cn", "flag-prt": "pt", "flag-bra": "br",
        "flag-deu": "de", "flag-fra": "fr", "flag-tur": "tr", "flag-ara": "sa", "flag-ces": "cz",
        "flag-dan": "dk", "flag-fin": "fi", "flag-heb": "il", "flag-hun": "hu", "flag-nld": "nl",
        "flag-nor": "no", "flag-pol": "pl", "flag-ron": "ro", "flag-swe": "se", "flag-tha": "th",
        "flag-ukr": "ua", "flag-vie": "vn",
    ]

    private static var cache: [String: UIImage] = [:]
    private static var missing: Set<String> = []

    /// The upstream flag art for a language, read once from the asset catalog; nil when flag.tsx
    /// has no file for it or the imageset is not in the bundle.
    static func image(for language: String) -> UIImage? {
        guard let name = file[language] else { return nil }
        if let hit = cache[name] { return hit }
        if missing.contains(name) { return nil }
        guard let img = UIImage(named: name) else {
            missing.insert(name)
            return nil
        }
        cache[name] = img
        return img
    }

    /// The emoji flag for a language: its flag-icons country, else the country of its upstream
    /// file (only reached when that file's imageset is missing). nil when neither has one.
    static func emoji(for language: String) -> String? {
        if let cc = country[language] { return emoji(country: cc) }
        if let name = file[language], let cc = fileCountry[name] { return emoji(country: cc) }
        return nil
    }

    /// Regional-indicator pair for an ISO 3166 code; Wales has its tag sequence; the Spanish
    /// regions (es-ct, es-pv, es-ga) have no emoji flag.
    static func emoji(country cc: String) -> String? {
        if cc == "gb-wls" { return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}" }
        let letters: [Unicode.Scalar] = Array(cc.lowercased().unicodeScalars)
        guard letters.count == 2 else { return nil }
        var out: String = ""
        for letter in letters {
            guard letter.value >= 97, letter.value <= 122,
                  let indicator = Unicode.Scalar(0x1F1E6 + letter.value - 97) else { return nil }
            out.unicodeScalars.append(indicator)
        }
        return out
    }
}


/// components/format-badge.tsx's images, read once from the bundle's badges/ folder (a missing file
/// is remembered too, so a row falls back to the badge's name without asking again on every redraw).
@MainActor
enum PhoneBadgeArt {
    private static var cache: [String: UIImage] = [:]
    private static var missing: Set<String> = []

    static func image(_ file: String) -> UIImage? {
        if let hit = cache[file] { return hit }
        if missing.contains(file) { return nil }
        let name: String = (file as NSString).deletingPathExtension
        let ext: String = (file as NSString).pathExtension
        guard let path = Bundle.main.path(forResource: name, ofType: ext, inDirectory: "badges"),
              let img = UIImage(contentsOfFile: path) else {
            missing.insert(file)
            return nil
        }
        cache[file] = img
        return img
    }
}

/// components/flag.tsx FlagStack at the row's size: the first `maxCount` languages as flags,
/// "Multi" as an accent "M" chip, a language with no flag as its first two letters, then "+{n}".
struct PhoneFlagStack: View {
    let languages: [String]
    var maxCount: Int = 4
    /// Grows with Dynamic Type, as the row's text does.
    @ScaledMetric(relativeTo: .caption) private var h: CGFloat = 12

    /// bp-stream-row.tsx: `stream.audioLanguages.filter((l) => l.toLowerCase() !== "unknown")`.
    static func streamLanguages(_ audioLanguages: [String]?) -> [String] {
        (audioLanguages ?? []).filter { $0.lowercased() != "unknown" }
    }

    var body: some View {
        let shown: [String] = Array(languages.prefix(max(0, maxCount)))
        let extra: Int = languages.count - shown.count
        HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { pair in
                cell(pair.element)
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(PhoneTheme.sans(11, .semibold, relativeTo: .caption2)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: languages.joined(separator: ", ")))
    }

    @ViewBuilder private func cell(_ lang: String) -> some View {
        if lang == "Multi" {
            Text(verbatim: "M")
                .font(PhoneTheme.sans(9, .heavy, relativeTo: .caption2)).tracking(1.2).foregroundStyle(BP.accent).lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: h + 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(BP.accent.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(BP.accent.opacity(0.35), lineWidth: 1))
        } else if let art = PhoneFlagArt.image(for: lang) {
            Image(uiImage: art).resizable().scaledToFill()
                .frame(width: h * 1.5, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.4), radius: 1, y: 1)
        } else if let flag = PhoneFlagArt.emoji(for: lang) {
            Text(verbatim: flag)
                .font(.system(size: h * 1.2)).lineLimit(1).fixedSize()
                .frame(width: h * 1.5, height: h)
        } else {
            Text(verbatim: String(lang.prefix(2)).uppercased())
                .font(PhoneTheme.sans(9, .bold, relativeTo: .caption2)).tracking(1).foregroundStyle(BP.inkSubtle).lineLimit(1)
                .padding(.horizontal, 3)
                .frame(height: h + 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(BP.canvas.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(BP.edge, lineWidth: 1))
        }
    }
}

/// format-badge.tsx FormatBadge: the badge image at the row's height, else its name in a chip.
struct PhoneFormatBadge: View {
    let format: ScoredStream.Labels.Format
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 15

    var body: some View {
        if let art = PhoneBadgeArt.image(format.file) {
            let aspect: CGFloat = art.size.height > 0 ? art.size.width / art.size.height : 1
            Image(uiImage: art).resizable().scaledToFit()
                .frame(width: min(height * 3.4, height * aspect), height: height)
                .shadow(color: Color.black.opacity(0.5), radius: 1)
                .accessibilityLabel(Text(verbatim: format.text))
        } else {
            PhoneTextBadge(text: format.text)
        }
    }
}

/// The small uppercase chip a badge with no art (or a home-server copy's quality) is written in.
struct PhoneTextBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(10, .bold, relativeTo: .caption2)).textCase(.uppercase).tracking(0.4)
            .foregroundStyle(BP.ink).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(BP.ink.opacity(0.1)))
    }
}

/// bp-stream-row.tsx META (`flex flex-wrap`): the row's pills left to right, wrapping onto another
/// line when they run out of room instead of squeezing.
struct PhoneFlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth: CGFloat = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size: CGSize = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size: CGSize = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
