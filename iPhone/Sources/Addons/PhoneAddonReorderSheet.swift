import SwiftUI

/// views/addons/organize/page.tsx on the phone (AddonOrganizeView on the TV), over the shared
/// AddonOrganizeModel: the Stremio account's addon order (synced to every Stremio app) and the
/// addons that live only on this phone. Hold a row and drag it, or use its menu (Move to top, up,
/// down, to bottom); nothing is written until Save, which runs the engine's checks (validate,
/// re-read for changes made elsewhere, back up, write, read back) exactly as the TV's Save does.
struct PhoneAddonReorderSheet: View {
    typealias Section = AddonOrganizeModel.Section
    typealias Row = AddonOrganizeModel.Row

    @ObservedObject var model: AddonsModel
    let close: () -> Void
    @StateObject private var organize: AddonOrganizeModel

    init(model: AddonsModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _organize = StateObject(wrappedValue: AddonOrganizeModel(authKey: model.authKey, onSaved: { text in
            Task { await model.reordered(toast: text) }
            close()
        }))
    }

    var body: some View {
        NavigationStack {
            Group {
                if organize.loading && !organize.settled {
                    ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if organize.loadError {
                    ErrorPlate(title: T("Couldn't load your Stremio collection. Nothing can be reordered safely without it."),
                               retry: { Task { await organize.load() } })
                        .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(PhoneBackground())
            .navigationTitle(T("Organize addons"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T("Cancel"), action: close)
                        .disabled(organize.locked)
                        .accessibilityIdentifier("reorder-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await organize.save() } } label: {
                        if let step = organize.saving { Text(Self.stepLabel(step)) } else { Text(T("Save")) }
                    }
                    .disabled(!organize.dirty || organize.locked || organize.loading)
                    .accessibilityIdentifier("reorder-save")
                }
            }
        }
        // Leaving discards the edits: no swipe-down past unsaved ones or a save under way.
        .interactiveDismissDisabled(organize.dirty || organize.locked)
        .task { await organize.load(reset: true) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reorder-sheet")
    }

    private var list: some View {
        List {
            SwiftUI.Section {
                Text(T("This order drives your catalog rows and the default stream order. A stream priority set in Settings overrides it for streams."))
                    .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                    .listRowBackground(Color.clear)
                if let n = organize.notice { notice(n) }
            }
            if organize.signedIn {
                section(.cloud, title: T("Your Stremio account"), footer: T("This order syncs to every Stremio app signed into this account."),
                        rows: organize.cloud, empty: T("No addons are synced to this account yet."))
                if !organize.device.isEmpty {
                    section(.device, title: T("On this device only"), footer: T("These live in Harbor on this phone and never touch your account."),
                            rows: organize.device, empty: nil)
                    SwiftUI.Section {
                        Button { Task { await organize.moveAll() } } label: {
                            Label(organize.moving ? T("Checking") : T("Move all to account"), systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(organize.saving != nil || organize.dirty || organize.moving)
                        .accessibilityIdentifier("reorder-move-all")
                    }
                }
                backups
            } else {
                section(.device, title: T("On this device"), footer: T("Sign in to Stremio to organize the addons synced to your account."),
                        rows: organize.device, empty: nil)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .disabled(organize.locked)
    }

    private func section(_ which: Section, title: String, footer: String, rows: [Row], empty: String?) -> some View {
        SwiftUI.Section {
            if rows.isEmpty, let empty {
                Text(verbatim: empty)
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                    .foregroundStyle(BP.inkSubtle)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                rowView(which, row, index: i, count: rows.count)
            }
            .onMove { from, to in
                guard let first = from.first else { return }
                PhoneFeedback.shared.selection()
                organize.move(which, from: first, to: PhoneAddonOrder.target(from: first, toOffset: to))
            }
        } header: {
            HStack {
                Text(verbatim: title)
                Spacer()
                Text(verbatim: rows.count == 1 ? T("%lld addon", rows.count) : T("%lld addons", rows.count))
            }
        } footer: {
            Text(verbatim: footer)
        }
    }

    private func rowView(_ which: Section, _ row: Row, index i: Int, count: Int) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(i + 1)")
                .font(PhoneTheme.sans(15, .bold, relativeTo: .subheadline).monospacedDigit())
                .foregroundStyle(BP.inkSubtle)
                .frame(minWidth: 24)
            PhoneAddonLogo(url: row.logo, name: row.name, side: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name)
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                Text(verbatim: row.host)
                    .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                    .foregroundStyle(BP.inkSubtle)
                    .lines(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button { move(which, i, to: 0) } label: { Label(T("Move to top"), systemImage: "arrow.up.to.line") }
                    .disabled(i == 0)
                    .accessibilityIdentifier("reorder-to-top")
                Button { move(which, i, to: i - 1) } label: { Label(T("Move up"), systemImage: "arrow.up") }
                    .disabled(i == 0)
                    .accessibilityIdentifier("reorder-up")
                Button { move(which, i, to: i + 1) } label: { Label(T("Move down"), systemImage: "arrow.down") }
                    .disabled(i >= count - 1)
                    .accessibilityIdentifier("reorder-down")
                Button { move(which, i, to: count - 1) } label: { Label(T("Move to bottom"), systemImage: "arrow.down.to.line") }
                    .disabled(i >= count - 1)
                    .accessibilityIdentifier("reorder-to-bottom")
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BP.inkSubtle)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(T("Move %@", row.name)))
            .accessibilityIdentifier("reorder-move-\(row.name)")
        }
        .listRowBackground(Color.clear.background(.ultraThinMaterial))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reorder-row-\(row.name)")
    }

    private func move(_ which: Section, _ from: Int, to: Int) {
        PhoneFeedback.shared.selection()
        organize.move(which, from: from, to: to)
    }

    private func notice(_ n: AddonOrganizeModel.Notice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: n.text)
                .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                .foregroundStyle(n.danger ? BP.danger : BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if n.retry || n.reload {
                HStack(spacing: 10) {
                    if n.retry { Button(T("Retry")) { Task { await organize.save() } }.buttonStyle(.glass) }
                    if n.reload { Button(T("Reload list")) { Task { await organize.load() } }.buttonStyle(.glass) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reorder-notice")
    }

    /// organize/backups-card.tsx: the last five orders, a backup now, one-tap restore.
    private var backups: some View {
        SwiftUI.Section {
            DisclosureGroup(isExpanded: Binding(get: { organize.backupsOpen }, set: { open in
                if open != organize.backupsOpen { organize.toggleBackups() }
            })) {
                Button(T("Back up current order")) { Task { await organize.backupNow() } }
                    .disabled(organize.cloud.isEmpty || organize.locked)
                if organize.backups.isEmpty {
                    Text(T("No backups yet. Press the button above to save your first one."))
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(BP.inkSubtle)
                }
                ForEach(organize.backups) { b in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Date(timeIntervalSince1970: b.at / 1000).formatted(date: .abbreviated, time: .shortened))
                                .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(BP.ink)
                            Text(verbatim: T("%lld addons", b.count) + " · " + Self.namesLine(b.names))
                                .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                                .foregroundStyle(BP.inkSubtle)
                                .lines(1)
                        }
                        Spacer()
                        Button(T("Restore")) { Task { await organize.restore(b.index) } }
                            .buttonStyle(.glass)
                            .disabled(organize.locked)
                    }
                }
            } label: {
                Label(organize.backups.isEmpty ? T("Backups") : "\(T("Backups")) · \(organize.backups.count)", systemImage: "clock.arrow.circlepath")
            }
        } footer: {
            Text(T("A safety copy of your addon order. One is saved automatically before Harbor writes any change, and you can save one yourself any time. The five most recent are kept."))
        }
    }

    /// backups-card.tsx namesLine: three names, then "+N more".
    private static func namesLine(_ names: [String]) -> String {
        let first = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? T("%@ +%lld more", first, names.count - 3) : first
    }

    private static func stepLabel(_ s: String) -> String {
        switch s {
        case "saving": return T("Saving")
        case "verifying": return T("Verifying")
        default: return T("Checking")
        }
    }
}
