import SwiftUI

/// X-Ray on the phone (components/player/xray/*): the cast, crew and about of what is playing, from the
/// same PlayerXRayModel the TV reads (`xray.load`). A sheet over the paused picture. The cards do not open
/// person pages: those live in the browse stack under the player cover.
struct PhoneXRaySheet: View {
    let meta: Meta?
    let onClose: () -> Void
    @StateObject private var model = PlayerXRayModel()
    @State private var tab = ""

    var body: some View {
        PhoneSheetFrame(panel: .xray, line: meta?.name, onClose: onClose) {
            if let data = model.payload {
                if data.hasDetails {
                    if data.tabs.count > 1 {
                        PhoneFlowRow(spacing: 8, lineSpacing: 8) {
                            ForEach(data.tabs, id: \.id) { t in
                                PhoneOptionChip(id: "panel-xray-tab-\(t.id)", title: t.label, selected: shownTab(data) == t.id) { tab = t.id }
                            }
                        }
                    }
                    switch shownTab(data) {
                    case "about": if let a = data.about { about(a) }
                    case "crew": people(data.crew, empty: data.empty.crew)
                    default: people(data.cast, empty: data.empty.cast)
                    }
                } else {
                    PhoneNote(text: data.empty.details).accessibilityIdentifier("panel-xray-empty")
                }
            } else if model.failed {
                PhoneNote(text: T("No cast information for this title.")).accessibilityIdentifier("panel-xray-empty")
            } else {
                ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, minHeight: 120)
                    .accessibilityIdentifier("panel-xray-loading")
            }
        }
        .task { if let meta { await model.load(meta) } }
    }

    /// The tab on show: the viewer's, else the answer's first.
    private func shownTab(_ data: PlayerXRayModel.Payload) -> String {
        if !tab.isEmpty, data.tabs.contains(where: { $0.id == tab }) { return tab }
        return data.initialTab ?? data.tabs.first?.id ?? "cast"
    }

    @ViewBuilder private func people(_ list: [PlayerXRayModel.Person], empty: String) -> some View {
        if list.isEmpty {
            PhoneNote(text: empty).accessibilityIdentifier("panel-xray-empty")
        } else {
            ForEach(list, id: \.key) { p in
                HStack(spacing: 12) {
                    ZStack {
                        PhoneImage(url: p.photo)
                        if p.photo == nil {
                            Text(verbatim: p.initials).font(PhoneTheme.sans(15, .bold, relativeTo: .body)).foregroundStyle(BP.inkMuted)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: p.name).font(PhoneTheme.sans(16, .semibold, relativeTo: .body)).foregroundStyle(BP.ink)
                        if let sub = p.sub, !sub.isEmpty {
                            Text(verbatim: sub).font(PhoneTheme.sans(13, .medium, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.panel))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("panel-xray-person-\(p.key)")
            }
        }
    }

    @ViewBuilder private func about(_ a: PlayerXRayModel.About) -> some View {
        Text(verbatim: a.title).font(PhoneTheme.display(20, .semibold, relativeTo: .title3)).foregroundStyle(BP.ink)
        let line: String = [a.year, a.runtime, a.rating.map { "★ \($0)" }, a.status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !line.isEmpty { PhoneNote(text: line) }
        if !a.genres.isEmpty { PhoneNote(text: a.genres.joined(separator: " · ")) }
        if let tag = a.tagline, !tag.isEmpty {
            Text(verbatim: tag).font(PhoneTheme.sans(15, .semibold, relativeTo: .body)).foregroundStyle(BP.ink)
        }
        if let o = a.overview, !o.isEmpty {
            Text(verbatim: o).font(PhoneTheme.sans(15, .regular, relativeTo: .body)).foregroundStyle(BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(a.facts, id: \.self) { f in
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: f.label).font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline)).foregroundStyle(BP.inkMuted)
                Spacer(minLength: 12)
                Text(verbatim: f.value).font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline)).foregroundStyle(BP.ink)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
