import SwiftUI

/// The pieces the phone player's panel sheets are built from: a header with the panel's
/// name and a Close, rows, chips and notes. The sheet itself (detents, glass background) is the
/// system's; everything here sits on it.

/// A panel's frame: its icon and name (with a line under it saying what is on), a Close, and the
/// content scrolling beneath. `sheetID` is what the UI tests look for.
struct PhoneSheetFrame<Content: View>: View {
    let panel: PhonePlayerPanel
    var line: String?
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label { Text(verbatim: panel.title) } icon: { Image(systemName: panel.icon) }
                        .font(PhoneTheme.display(22, .semibold, relativeTo: .title3))
                        .foregroundStyle(BP.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("player-sheet-title")
                    if let line, !line.isEmpty {
                        Text(verbatim: line)
                            .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                            .lines(1)
                            .accessibilityIdentifier("player-sheet-line")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    PhoneFeedback.shared.tap()
                    onClose()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text(verbatim: T("Close")))
                .accessibilityIdentifier("player-sheet-close")
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.top, 20)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(.horizontal, PhoneTheme.margin)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(panel.sheetID)
    }
}

/// One choice in a list: a track, a source, a quality. The one in use wears a check.
struct PhonePanelRow: View {
    let id: String
    var icon: String = "circle"
    let title: String
    var detail: String?
    var badges: [String] = []
    var selected = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button {
            PhoneFeedback.shared.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(PhoneTheme.sans(16, .semibold, relativeTo: .body)).foregroundStyle(BP.ink)
                        .multilineTextAlignment(.leading)
                    if let detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                            .multilineTextAlignment(.leading)
                    }
                    if !badges.isEmpty {
                        Text(verbatim: badges.joined(separator: " · "))
                            .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2)).textCase(.uppercase).tracking(0.8)
                            .foregroundStyle(BP.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if busy {
                    ProgressView().tint(BP.ink).accessibilityHidden(true)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? BP.accent : BP.inkSubtle)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(selected ? BP.panel2 : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous)
                .stroke(selected ? BP.accent.opacity(0.6) : BP.edge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier(id)
    }
}

/// A small glass option: a speed, a sleep length, a sync step. The one in use is tinted.
struct PhoneOptionChip: View {
    let id: String
    let title: String
    var systemImage: String?
    var selected = false
    var label: String?
    let action: () -> Void

    var body: some View {
        let glass: Glass = selected ? Glass.regular.tint(BP.accent).interactive() : Glass.regular.interactive()
        Button {
            PhoneFeedback.shared.selection()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.footnote.weight(.semibold)) }
                Text(verbatim: title).font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline)).monospacedDigit()
            }
            .foregroundStyle(selected ? BP.on : BP.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(glass, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label ?? title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier(id)
    }
}

/// A small section title over a group of rows or chips.
struct PhoneSectionLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(12, .bold, relativeTo: .caption)).textCase(.uppercase).tracking(1)
            .foregroundStyle(BP.inkSubtle)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A line of quiet copy: an empty list, a hint.
struct PhoneNote: View {
    let text: String
    var tone: Color = BP.inkMuted

    var body: some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline)).foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }
}

/// Hands the sleep timer's face ("12:30", "End ep") to a HUD button; only this leaf redraws as it counts down.
struct PhoneSleepFace<Content: View>: View {
    @ObservedObject private var timer = SleepTimer.shared
    private let content: (String?) -> Content

    init(@ViewBuilder content: @escaping (String?) -> Content) { self.content = content }

    var body: some View { content(timer.faceLabel) }
}
