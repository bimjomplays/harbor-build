import SwiftUI

/// The top-bar entry to the account area: the profile glyph that opens the menu below.
struct AccountMenuButton: View {
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: BP.px(17), weight: .semibold))
        }
        .buttonStyle(BPTabStyle(active: false))
        .accessibilityIdentifier("account-menu")
        .accessibilityLabel(Text(verbatim: T("Account")))
        .fullScreenCover(isPresented: $open) { AccountMenuView() }
    }
}

/// The account menu on the TV: Who's watching and Settings. Everything that needed a Harbor
/// account (profile page, notifications, activity, groups, shared lists, Watch Together) went
/// with the service.
struct AccountMenuView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var profiles = ProfilesStore.shared
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focus: String?
    /// onAppear also runs when a page opened from here closes; the seed is placed once, when the menu opens.
    @State private var seeded = false

    var body: some View {
        ZStack {
            BPAmbientBackground()
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(18)) {
                header
                VStack(alignment: .leading, spacing: BP.px(8)) {
                    item("Who's watching?", "person.2.circle", key: "who") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.switchProfile() } }
                    item("Settings", "gearshape", key: "settings") {
                        app.room = .settings
                        dismiss()
                    }
                }
                .focusSection()
            }
            .padding(BP.px(34))
            .frame(width: BP.px(560))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .onExitCommand { dismiss() }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = "who" }
        }
    }

    private var header: some View {
        HStack(spacing: BP.px(14)) {
            if let p = profiles.active { ProfileFace(profile: p, size: BP.px(52)).accessibilityHidden(true) }
            Text(profiles.active?.name ?? "Harbor").font(BP.display(24)).foregroundStyle(BP.ink)
        }
    }

    private func item(_ label: String, _ icon: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BP.px(12)) {
                Image(systemName: icon).frame(width: BP.px(24)).accessibilityHidden(true)
                Text(T(label))
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BPActionStyle())
        .focused($focus, equals: key)
        .accessibilityIdentifier("account-item-" + key)
    }
}
