import SwiftUI

/// The title page's dialogs, each a sheet with detents: the trailer,
/// Rate (bp-rate-dialog), Add to list (bp-list-dialog), the facts (bp-facts-dialog), an award body
/// (bp-award-detail-dialog), a tracker's list status (bp-status-dialog) and the tracker sign-ins
/// (the TV's TraktPanel / PasteTrackerPanel). The gallery opens its own full-screen lightbox
/// (PhoneGalleryRail) and the play picker comes through PhonePlay.
enum PhoneDetailDialog: Identifiable {
    case trailer(ytId: String, name: String?)
    case rate
    case lists
    case facts
    case awards(DetailModel.TitleAwards.Group)
    case tracker(DetailModel.Tracker)
    case trackers

    var id: String {
        switch self {
        case .trailer(let yt, _): return "trailer-\(yt)"
        case .rate: return "rate"
        case .lists: return "lists"
        case .facts: return "facts"
        case .awards(let group): return "awards-\(group.type)"
        case .tracker(let tracker): return "tracker-\(tracker.key)"
        case .trackers: return "trackers"
        }
    }
}

/// A dialog sheet's frame: the title in an inline bar with Done, the content scrolling under it,
/// medium and large detents (or the ones given) and the grabber. The sheet keeps iOS 26's glass.
struct PhoneDialogPage<Content: View>: View {
    let title: String
    let identifier: String
    var detents: Set<PresentationDetent> = [.medium, .large]
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                content()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T("Done"), action: close).accessibilityIdentifier("\(identifier)-done")
                }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentedCover("dialog")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// The small upper-case caption over a group of rows.
private struct DialogCaption: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(BP.inkSubtle)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rows on one soft plate, split by hairlines (a grouped list without List's chrome).
private struct DialogGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.ink.opacity(0.06)))
    }
}

private struct DialogDivider: View {
    var body: some View {
        Rectangle().fill(BP.ink.opacity(0.08)).frame(height: 1).padding(.leading, 16)
    }
}

// MARK: Facts

/// bp-facts-dialog.tsx: every fact row of the title, label over value.
struct PhoneFactsSheet: View {
    let title: String
    let facts: [DetailModel.Extras.Fact]
    let close: () -> Void

    var body: some View {
        PhoneDialogPage(title: T("Details"), identifier: "facts-sheet", close: close) {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: title)
                    .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("facts-title")
                DialogGroup {
                    ForEach(Array(facts.enumerated()), id: \.element.id) { i, f in
                        if i > 0 { DialogDivider() }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: T(f.label))
                                .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
                                .textCase(.uppercase)
                                .tracking(0.6)
                                .foregroundStyle(BP.inkSubtle)
                            Text(verbatim: f.value)
                                .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                                .foregroundStyle(BP.ink)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fact-\(i)")
                    }
                }
            }
        }
    }
}

// MARK: Awards

/// bp-award-detail-dialog.tsx: the body's wins, then its nominations, each newest year first.
struct PhoneAwardsSheet: View {
    let group: DetailModel.TitleAwards.Group
    let entries: [DetailModel.TitleAwards.Entry]
    let close: () -> Void

    var body: some View {
        let wins = Self.byYear(entries.filter { $0.result == "won" })
        let noms = Self.byYear(entries.filter { $0.result == "nominated" })
        PhoneDialogPage(title: group.title, identifier: "awards-sheet", close: close) {
            VStack(alignment: .leading, spacing: 20) {
                if !wins.isEmpty { section(TCount(wins.count, one: "%lld win", "%lld wins"), wins, icon: "trophy.fill", key: "won") }
                if !noms.isEmpty { section(TCount(noms.count, one: "%lld nomination", "%lld nominations"), noms, icon: "rosette", key: "nominated") }
            }
        }
    }

    /// byYear: `(b.year ?? 0) - (a.year ?? 0)`, stable.
    private static func byYear(_ list: [DetailModel.TitleAwards.Entry]) -> [DetailModel.TitleAwards.Entry] {
        list.enumerated().sorted { a, b in
            let ya = a.element.year ?? 0, yb = b.element.year ?? 0
            return ya != yb ? ya > yb : a.offset < b.offset
        }.map(\.element)
    }

    /// BpAwardLine: the year, then `e.category || e.awardName`.
    private static func line(_ e: DetailModel.TitleAwards.Entry) -> String {
        let category = e.category ?? ""
        let text = category.isEmpty ? e.awardName : category
        guard let year = e.year else { return text }
        return "\(year) · \(text)"
    }

    private func section(_ label: String, _ list: [DetailModel.TitleAwards.Entry], icon: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DialogCaption(text: label)
            DialogGroup {
                // Two nominations in one category and year (two supporting actors) share an Entry id.
                ForEach(Array(list.enumerated()), id: \.offset) { i, e in
                    if i > 0 { DialogDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(key == "won" ? BP.accent : BP.inkSubtle)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Self.line(e))
                                .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(BP.ink)
                            if let r = e.recipient, !r.isEmpty {
                                Text(verbatim: r)
                                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                                    .foregroundStyle(BP.inkMuted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("awards-\(key)")
        }
    }
}

// MARK: Rate

/// bp-rate-dialog.tsx: 1–10, the current score lit; a score rates and closes, "Remove rating" when
/// one exists. A score that stays on this device only says so instead of closing.
struct PhoneRateSheet: View {
    let meta: Meta
    let close: () -> Void
    @State private var score = 0
    @State private var note: String?
    @State private var busy = false
    private struct Rating: Decodable { var score: Int; var updatedAt: Double }

    var body: some View {
        PhoneDialogPage(title: T("Rate this"), identifier: "rate-sheet", detents: [.height(360), .large], close: close) {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: meta.name)
                    .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .lines(2)
                    .accessibilityAddTraits(.isHeader)
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) { ForEach(1...5, id: \.self) { scoreButton($0) } }
                        HStack(spacing: 10) { ForEach(6...10, id: \.self) { scoreButton($0) } }
                    }
                }
                .frame(maxWidth: .infinity)
                if score > 0 {
                    Button(role: .destructive) {
                        Task { await unrate() }
                    } label: {
                        Label(T("Remove rating"), systemImage: "star.slash")
                            .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("rate-remove")
                }
                if let note {
                    Text(verbatim: note)
                        .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                        .foregroundStyle(BP.inkMuted)
                        .accessibilityIdentifier("rate-note")
                }
            }
        }
        .task {
            let r: Rating? = try? await HarborEngine.shared.call("actions.rating", [meta.id]) as Rating
            score = r?.score ?? 0
        }
    }

    private func scoreButton(_ n: Int) -> some View {
        let lit = score > 0 && n <= score
        return Button {
            Task { await rate(n) }
        } label: {
            Text(verbatim: "\(n)")
                .font(PhoneTheme.sans(18, .semibold, relativeTo: .headline))
                .monospacedDigit()
                .foregroundStyle(lit ? BP.on : BP.ink)
                .frame(width: 52, height: 52)
                .glassEffect(lit ? Glass.regular.tint(BP.accent).interactive() : Glass.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(Text(verbatim: T("Your rating %lld/10", n)))
        .accessibilityAddTraits(n == score ? [.isSelected] : [])
        .accessibilityIdentifier("rate-\(n)")
    }

    private func rate(_ n: Int) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        struct Out: Decodable { var score: Int; var synced: Bool; var kept: Bool? }
        PhoneFeedback.shared.selection()
        guard let o: Out = try? await HarborEngine.shared.call("actions.rate", [meta, n]) else {
            PhoneFeedback.shared.failure()
            return
        }
        score = o.score
        if o.synced || o.kept == false {
            PhoneFeedback.shared.success()
            close()
            return
        }
        note = T("Saved on this device. Ratings are not synced to an account.")
    }

    private func unrate() async {
        _ = try? await HarborEngine.shared.callJSON("actions.unrate", [.string(meta.id)])
        score = 0
        PhoneFeedback.shared.success()
        close()
    }
}

// MARK: Lists

/// bp-list-dialog.tsx: every custom list with a tick when the title is in it; a tap toggles. A new
/// list is named in place and gets the title.
struct PhoneListSheet: View {
    let meta: Meta
    let close: () -> Void
    @State private var lists: [ListSummary] = []
    @State private var loaded = false
    @State private var naming = false
    @State private var newName = ""
    @State private var creating = false
    @FocusState private var nameFocused: Bool
    private struct ListSummary: Decodable, Identifiable { var id: String; var name: String; var count: Int; var contains: Bool }

    var body: some View {
        PhoneDialogPage(title: T("Add to list"), identifier: "lists-sheet", close: close) {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: meta.name)
                    .font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(BP.inkMuted)
                    .lines(1)
                if loaded, lists.isEmpty, !naming {
                    Text(verbatim: T("No lists yet"))
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .body))
                        .foregroundStyle(BP.inkMuted)
                        .accessibilityIdentifier("lists-empty")
                }
                if !lists.isEmpty {
                    DialogGroup {
                        ForEach(Array(lists.enumerated()), id: \.element.id) { i, l in
                            if i > 0 { DialogDivider() }
                            Button {
                                PhoneFeedback.shared.selection()
                                Task { await toggle(l) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: l.contains ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(l.contains ? BP.accent : BP.inkSubtle)
                                        .accessibilityHidden(true)
                                    Text(verbatim: l.name)
                                        .font(PhoneTheme.sans(16, .medium, relativeTo: .body))
                                        .foregroundStyle(BP.ink)
                                    Spacer(minLength: 8)
                                    Text(verbatim: "\(l.count)")
                                        .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                                        .monospacedDigit()
                                        .foregroundStyle(BP.inkSubtle)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(l.contains ? [.isSelected] : [])
                            .accessibilityIdentifier("list-\(l.id)")
                        }
                    }
                }
                if naming {
                    TextField(T("List name"), text: $newName)
                        .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { Task { await create() } }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.ink.opacity(0.08)))
                        .accessibilityIdentifier("list-name")
                    HStack(spacing: 10) {
                        Button(T("Cancel")) {
                            naming = false
                            newName = ""
                        }
                        .buttonStyle(.glass)
                        Button {
                            Task { await create() }
                        } label: {
                            Text(verbatim: T("Create")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(creating || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("list-create")
                    }
                } else {
                    Button {
                        naming = true
                        nameFocused = true
                    } label: {
                        Label(T("New list"), systemImage: "plus")
                            .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("list-new")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        lists = (try? await HarborEngine.shared.call("actions.lists", [meta.id])) ?? []
        loaded = true
    }

    private func toggle(_ l: ListSummary) async {
        let _: Bool? = try? await HarborEngine.shared.call("actions.toggleList", [l.id, meta]) as Bool
        await load()
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        // One at a time: a double tap on Create made two lists of the same name.
        guard !creating, !name.isEmpty else { return }
        creating = true
        defer { creating = false }
        let id: String? = try? await HarborEngine.shared.call("actions.newList", [name]) as String
        if let id { let _: Bool? = try? await HarborEngine.shared.call("actions.toggleList", [id, meta]) as Bool }
        naming = false
        newName = ""
        if id != nil { PhoneFeedback.shared.success() }
        await load()
    }
}

// MARK: Tracker status

/// bp-status-dialog.tsx: a signed-in tracker's statuses (the current one ticked) and "Remove from
/// list" when the title has an entry. A pick sets it and closes.
struct PhoneTrackerStatusSheet: View {
    let tracker: DetailModel.Tracker
    let onPick: (String) -> Void
    let onRemove: () -> Void
    let close: () -> Void

    var body: some View {
        PhoneDialogPage(title: tracker.name, identifier: "tracker-sheet", close: close) {
            VStack(alignment: .leading, spacing: 16) {
                DialogGroup {
                    ForEach(Array(tracker.choices.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { DialogDivider() }
                        let on = c.id == tracker.status
                        Button {
                            PhoneFeedback.shared.selection()
                            onPick(c.id)
                            close()
                        } label: {
                            HStack {
                                Text(verbatim: T(c.label))
                                    .font(PhoneTheme.sans(16, on ? .semibold : .regular, relativeTo: .body))
                                    .foregroundStyle(BP.ink)
                                Spacer()
                                if on {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(BP.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                        .accessibilityIdentifier("tracker-choice-\(c.id)")
                    }
                }
                if tracker.canRemove {
                    Button(role: .destructive) {
                        PhoneFeedback.shared.warning()
                        onRemove()
                        close()
                    } label: {
                        Label(T("Remove from list"), systemImage: "trash")
                            .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("tracker-remove")
                }
            }
        }
    }
}
