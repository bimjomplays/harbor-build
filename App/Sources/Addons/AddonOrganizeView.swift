import SwiftUI

/// views/addons/organize/page.tsx: the Stremio account's addon order (synced everywhere) and the
/// addons that live only on this TV, each reordered and saved with upstream's checks (validate,
/// re-read for changes made elsewhere, back up, write, read back) by the engine
/// (addonsManager.organize*). Upstream drags rows or uses the up / down / top buttons; on a TV,
/// Select on a row picks it up, Up and Down move it, Select drops it (Back also drops), and the
/// same buttons sit at the end of each row.
struct AddonOrganizeView: View {
    let authKey: String?
    let onClose: () -> Void

    typealias Section = AddonOrganizeModel.Section
    typealias Row = AddonOrganizeModel.Row
    typealias Notice = AddonOrganizeModel.Notice

    @StateObject private var model: AddonOrganizeModel
    /// The focus ring lives in this view (@FocusState); the model reads and moves it through the binding.
    /// It is bound to the row key, not its index, so a picked-up row keeps focus as it moves.
    @FocusState private var focusedRow: String?

    init(authKey: String?, onClose: @escaping () -> Void, onSaved: @escaping (String) -> Void) {
        self.authKey = authKey
        self.onClose = onClose
        _model = StateObject(wrappedValue: AddonOrganizeModel(authKey: authKey, onSaved: onSaved))
    }

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    header
                    if model.loading && !model.settled {
                        ProgressView().tint(BP.inkMuted)
                    } else if model.loadError {
                        loadErrorPanel
                    } else {
                        HStack(alignment: .top, spacing: BP.px(36)) {
                            VStack(alignment: .leading, spacing: BP.px(24)) {
                                if let n = model.notice { noticePanel(n).disabled(model.grabbed != nil) }
                                if model.signedIn {
                                    section(.cloud, title: T("Your Stremio account"), sub: T("This order syncs to every Stremio app signed into this account."), rows: model.cloud,
                                            empty: T("No addons are synced to this account yet."), action: nil)
                                    if !model.device.isEmpty {
                                        section(.device, title: T("On this device only"), sub: T("These live in Harbor on this computer and never touch your account."), rows: model.device,
                                                empty: nil, action: AnyView(moveAllButton))
                                    }
                                } else {
                                    section(.device, title: T("On this device"), sub: T("Sign in to Stremio to organize the addons synced to your account."), rows: model.device, empty: nil, action: nil)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            goodToKnow.frame(width: BP.px(440))
                        }
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(50))
            }
            .onChange(of: model.moved) { _, mark in
                guard let mark else { return }
                withAnimation(BP.easeFast) { proxy.scrollTo(mark.key) }
            }
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            if model.backPressed() { onClose() }
        }
        .onAppear {
            let ring = $focusedRow
            model.bindFocus(read: { ring.wrappedValue }, write: { ring.wrappedValue = $0 })
        }
        .task { await model.load(reset: true) }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: BP.px(16)) {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                Text(T("Organize addons")).font(BP.display(30, .medium)).foregroundStyle(BP.ink)
                Text(T("This order drives your catalog rows and the default stream order. A stream priority set in Settings overrides it for streams."))
                    .font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(2)
            }
            Spacer()
            if model.signedIn && !model.loadError {
                Button { model.toggleBackups() } label: {
                    Label(model.backups.isEmpty ? T("Backups") : "\(T("Backups")) · \(model.backups.count)", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(BPActionStyle(primary: model.backupsOpen))
            }
            if !model.loadError {
                Button(T("Cancel")) { onClose() }.buttonStyle(BPActionStyle()).disabled(model.locked)
                Button(model.saving.map(stepLabel) ?? T("Save order")) { Task { await model.save() } }
                    .buttonStyle(BPActionStyle(primary: true, busy: model.saving != nil)).disabled(!model.dirty || model.moving || model.loading)
            }
        }
        .disabled(model.grabbed != nil)
        .focusSection()
        .overlay(alignment: .topTrailing) {
            if model.backupsOpen { backupsPanel.offset(y: BP.px(90)) }
        }
        .zIndex(2)
    }

    private func stepLabel(_ s: String) -> String {
        switch s {
        case "saving": return T("Saving")
        case "verifying": return T("Verifying")
        default: return T("Checking")
        }
    }

    // MARK: sections (organize/section-card.tsx)

    private func section(_ which: Section, title: String, sub: String, rows: [Row], empty: String?, action: AnyView?) -> some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(alignment: .center, spacing: BP.px(12)) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(title).font(BP.display(21, .medium)).foregroundStyle(BP.ink)
                    Text(sub).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
                Spacer()
                if let action { action }
                Text(rows.count == 1 ? T("%lld addon", rows.count) : T("%lld addons", rows.count))
                    .font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                    .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4)).background(Capsule().fill(BP.edge))
            }
            if rows.isEmpty, let empty {
                Text(empty).font(BP.sans(14)).foregroundStyle(BP.inkSubtle).padding(BP.px(16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, style: StrokeStyle(lineWidth: 1, dash: [6])))
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                organizeRow(which, row, index: i, count: rows.count)
            }
        }
        .padding(BP.px(22))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        .focusSection()
    }

    private func organizeRow(_ which: Section, _ row: Row, index i: Int, count: Int) -> some View {
        let isGrabbed = model.grabbed == row.key
        let frozen = model.locked || (model.grabbed != nil && !isGrabbed)
        return HStack(spacing: BP.px(10)) {
            Button {
                withAnimation(BP.easeFast) { model.grabbed = isGrabbed ? nil : row.key }
            } label: {
                HStack(spacing: BP.px(14)) {
                    Image(systemName: isGrabbed ? "arrow.up.and.down" : "line.3.horizontal").foregroundStyle(isGrabbed ? BP.accent : BP.inkSubtle)
                        .accessibilityLabel(Text(T("Drag to reorder")))
                    Text("\(i + 1)").font(BP.sans(16, .bold)).monospacedDigit().foregroundStyle(BP.inkSubtle).frame(minWidth: BP.px(28))
                    AddonLogoView(url: row.logo, name: row.name, side: BP.px(40))
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        Text(row.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        Text(row.host).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(isGrabbed ? BP.accent.opacity(0.14) : BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(isGrabbed ? BP.accent.opacity(0.6) : BP.edge, lineWidth: isGrabbed ? 2 : 1))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .focused($focusedRow, equals: row.key)
            // A grabbed row (Up/Down move it) reads as selected.
            .bpSelected(isGrabbed)
            .onMoveCommand { dir in
                guard isGrabbed else { return }
                switch dir {
                case .up: model.move(which, from: i, to: i - 1)
                case .down: model.move(which, from: i, to: i + 1)
                default: break
                }
            }
            Button { model.move(which, from: i, to: i - 1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(BPActionStyle()).disabled(i == 0).accessibilityLabel(T("Move up"))
            Button { model.move(which, from: i, to: i + 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(BPActionStyle()).disabled(i >= count - 1).accessibilityLabel(T("Move down"))
            Button { model.move(which, from: i, to: 0) } label: { Image(systemName: "chevron.up.2") }
                .buttonStyle(BPActionStyle()).disabled(i == 0).accessibilityLabel(T("Move to top"))
        }
        .disabled(frozen)
    }

    private var moveAllButton: some View {
        Button { Task { await model.moveAll() } } label: {
            Label(model.moving ? T("Checking") : T("Move all to account"), systemImage: "icloud.and.arrow.up")
        }
        .buttonStyle(BPActionStyle(busy: model.moving))
        .disabled(model.saving != nil || model.dirty || model.grabbed != nil)
    }

    // MARK: side panels

    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Label(T("Good to know"), systemImage: "info.circle").font(BP.display(18, .medium)).foregroundStyle(BP.ink)
            ForEach([
                "Number 1 answers first when you press Play, unless Settings has a stream priority.",
                "The order also decides which addon's rows win on your Home screen.",
                "Nothing changes until you press Save. Leaving this page discards edits.",
                "The Backups button at the top keeps your last five orders. One click restores any of them.",
                "Harbor double-checks with Stremio after saving, so a half-written order can't slip through.",
            ], id: \.self) { line in
                Text("• " + T(line)).font(BP.sans(13)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            BPNote(text: "Press Select on an addon to pick it up, move it with Up and Down, then press Select again to drop it.", tone: BP.inkSubtle)
        }
        .padding(BP.px(20))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }

    /// organize/backups-card.tsx.
    private var backupsPanel: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(T("A safety copy of your addon order. One is saved automatically before Harbor writes any change, and you can save one yourself any time. The five most recent are kept."))
                .font(BP.sans(12)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            Button(T("Back up current order")) { Task { await model.backupNow() } }
                .buttonStyle(BPActionStyle()).disabled(model.cloud.isEmpty || model.locked)
            if model.backups.isEmpty {
                Text(T("No backups yet. Press the button above to save your first one.")).font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            ForEach(model.backups) { b in
                HStack(spacing: BP.px(12)) {
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        Text(Date(timeIntervalSince1970: b.at / 1000).formatted(date: .abbreviated, time: .shortened)).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                        Text(T("%lld addons", b.count) + " · " + namesLine(b.names)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    Spacer()
                    Button(T("Restore")) { Task { await model.restore(b.index) } }.buttonStyle(BPActionStyle()).disabled(model.locked)
                }
            }
        }
        .padding(BP.px(18))
        .frame(width: BP.px(520))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.elevated))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge2, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        .focusSection()
    }

    /// backups-card.tsx namesLine: three names, then "+N more".
    private func namesLine(_ names: [String]) -> String {
        let first = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? T("%@ +%lld more", first, names.count - 3) : first
    }

    private func noticePanel(_ n: Notice) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(n.text).font(BP.sans(14)).foregroundStyle(n.danger ? BP.danger : BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            if n.retry || n.reload {
                HStack(spacing: BP.px(10)) {
                    if n.retry { Button(T("Retry")) { Task { await model.save() } }.buttonStyle(BPActionStyle()) }
                    if n.reload { Button(T("Reload list")) { Task { await model.load() } }.buttonStyle(BPActionStyle()) }
                }
                .focusSection()
            }
        }
        .padding(BP.px(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(n.danger ? BP.danger.opacity(0.15) : BP.panel2))
    }

    private var loadErrorPanel: some View {
        VStack(spacing: BP.px(18)) {
            Text(T("Couldn't load your Stremio collection. Nothing can be reordered safely without it.")).font(BP.sans(16)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center)
            HStack(spacing: BP.px(12)) {
                Button(T("Try again")) { Task { await model.load() } }.buttonStyle(BPActionStyle(primary: true))
                Button(T("Go back")) { onClose() }.buttonStyle(BPActionStyle())
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity).padding(BP.px(60))
    }
}
