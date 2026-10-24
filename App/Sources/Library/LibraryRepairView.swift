import SwiftUI


struct LibraryRepairPanel: View {
    @StateObject private var model = LibraryRepairModel()
    let onRepaired: () -> Void

    init(onRepaired: @escaping () -> Void) { self.onRepaired = onRepaired }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            if model.authKey == nil {
                row("Repair library", "Sign in to Stremio first. The repair scans only the active profile's library.", tone: BP.inkMuted)
                row("Repair anime library", "Sign in to Stremio first. This scans the active profile's library.", tone: BP.inkMuted)
            } else {
                HStack(alignment: .center, spacing: BP.px(16)) {
                    row("Repair library", model.line, tone: (model.outcome?.repaired ?? 0) > 0 && model.failure == nil ? BP.live : BP.inkMuted)
                    Spacer(minLength: BP.px(12))
                    Button {
                        guard !model.busy else { return }
                        Task {
                            await model.run()
                            onRepaired()
                        }
                    } label: { Label(T(model.cta), systemImage: "wrench.and.screwdriver") }
                    .buttonStyle(BPActionStyle(primary: model.outcome == nil, busy: model.busy))
                }
                HStack(alignment: .center, spacing: BP.px(16)) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        row("Fix corrupted anime", model.animeLine, tone: model.showRemove ? BP.danger : (model.animePhase == "done" && model.removed > 0 ? BP.live : BP.inkMuted))
                        if model.showRemove {
                            Text("This deletes those entries from your library. Playing them again re-adds them.")
                                .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                        }
                    }
                    Spacer(minLength: BP.px(12))
                    Button {
                        guard !model.animeBusy else { return }
                        Task {
                            let removing = model.showRemove
                            await model.animeAction()
                            if removing { onRepaired() }
                        }
                    } label: { Label(T(model.animeCta), systemImage: "wrench.and.screwdriver") }
                    .buttonStyle(BPActionStyle(primary: model.showRemove, busy: model.animeBusy))
                }
            }
        }
        .padding(BP.px(18))
        .frame(maxWidth: BP.px(1100), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .focusSection()
    }

    private func row(_ label: String, _ sub: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: BP.px(4)) {
            Text(T(label)).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text(T(sub)).font(BP.sans(13)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
