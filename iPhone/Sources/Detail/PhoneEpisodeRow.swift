import SwiftUI

/// One episode on the title page ("episode rows"; DetailView's EpisodeCard
/// on the TV, bp-episode-card.tsx upstream): the still with its tag, watched mark, unaired pill and
/// resume bar, then the title, the facts line and the overview. The profile's spoiler settings blur
/// the still, title and overview (lib/spoilers.ts spoilerMaskFor, which already lifts it once the
/// episode is watched); a phone has no focus to lift it for a look, as the TV does.
struct PhoneEpisodeRow: View {
    let episode: DetailModel.Episode
    var watched = false
    var fact: DetailModel.EpisodeFact? = nil
    /// use-bp-episode-art's first still; nil draws the plate.
    var still: String? = nil
    var spoiler: DetailModel.SpoilerMask? = nil
    var showRating = true
    var showDescription = true
    /// The resume episode's progress (0...1).
    var progress: Double = 0
    /// The episode the page was opened on (an AI search pick).
    var highlighted = false
    let action: () -> Void

    private static let stillSize = CGSize(width: 148, height: 83)

    private var hideThumb: Bool { spoiler?.thumb == true }
    private var hideTitle: Bool { spoiler?.title == true }
    private var hideDesc: Bool { spoiler?.desc == true }
    private var unaired: Bool { (episode.released ?? .distantPast) > Date() }
    private var tag: String { episode.tag ?? "E\(episode.episode)" }

    /// bp-anime-seasons.tsx facts and use-bp-episode-facts: "Abs E{n}" · the air date · runtime · rating.
    private var factsLine: String {
        var parts: [String] = []
        if let a = episode.absoluteLabel { parts.append(a) }
        if let d = episode.released { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        if let m = fact?.runtime { parts.append("\(m) min") }
        if showRating, let f = fact, let r = f.rating { parts.append((f.ratingIsImdb ? "IMDb " : "★ ") + String(format: "%.1f", r)) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [T("Episode %lld", episode.episode)]
        if !hideTitle, !episode.title.isEmpty { parts.append(episode.title) }
        if watched { parts.append(T("Watched")) }
        if unaired { parts.append(T("Unaired")) }
        if episode.filler { parts.append(T("Filler")) }
        if !factsLine.isEmpty { parts.append(factsLine) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                stillView
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: episode.title)
                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                        .multilineTextAlignment(.leading)
                        .blur(radius: hideTitle ? 6 : 0)
                    if !factsLine.isEmpty {
                        Text(verbatim: factsLine)
                            .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                            .monospacedDigit()
                            .foregroundStyle(BP.inkSubtle)
                            .lines(1)
                    }
                    if showDescription, let o = episode.overview, !o.isEmpty {
                        Text(verbatim: o)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                            .lines(3)
                            .multilineTextAlignment(.leading)
                            .blur(radius: hideDesc ? 5 : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous)
                    .fill(highlighted ? BP.accent.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous)
                    .stroke(BP.accent.opacity(highlighted ? 0.75 : 0), lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAddTraits(traits)
        .accessibilityIdentifier("episode-\(episode.season)-\(episode.episode)")
    }

    private var traits: AccessibilityTraits { highlighted ? [.isButton, .isSelected] : [.isButton] }

    private var stillView: some View {
        ZStack(alignment: .bottomLeading) {
            PhoneImage(url: PhoneArt.still(still))
                // BP_SPOILER_THUMB: blur-[16px] scale-[1.05].
                .blur(radius: hideThumb ? 14 : 0)
                .scaleEffect(hideThumb ? 1.08 : 1)
            if still == nil {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(BP.inkSubtle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, BP.void_.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 6) {
                Text(verbatim: tag)
                    .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                    .foregroundStyle(BP.ink)
                if episode.filler {
                    Text(verbatim: T("Filler"))
                        .font(PhoneTheme.sans(9, .bold, relativeTo: .caption2))
                        .textCase(.uppercase)
                        .foregroundStyle(BP.ink)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(BP.void_.opacity(0.82)))
                }
            }
            .padding(6)
            if watched {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BP.canvas)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(BP.ink))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if unaired {
                Text(verbatim: T("Unaired"))
                    .font(PhoneTheme.sans(9, .bold, relativeTo: .caption2))
                    .textCase(.uppercase)
                    .foregroundStyle(BP.canvas)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(BP.ink))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if progress > 0.01, progress < 0.97 {
                ZStack(alignment: .leading) {
                    BP.void_.opacity(0.6)
                    BP.accent.frame(width: Self.stillSize.width * progress)
                }
                .frame(height: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(width: Self.stillSize.width, height: Self.stillSize.height)
        .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
    }
}
