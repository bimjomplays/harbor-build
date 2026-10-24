import SwiftUI

/// The profile button's sheet: who is watching, then the places that are not tabs (Settings, Trackers, Addons,
/// About). Addons pushes inside the sheet, and its
/// pages push again (an addon, its catalogs, a title, Play): the sheet is a tab stack of its own.
struct PhoneAccountSheet: View {
    /// Its presence id: PhonePlay sends a Play made inside the sheet to the sheet's own play host.
    static let presenceId = "account"

    let close: () -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var parental = ParentalGate.shared

    var body: some View {
        PhoneTabStack { _ in
            ScrollView {
                VStack(spacing: 20) {
                    if let profile = profiles.active {
                        VStack(spacing: 10) {
                            ProfileFace(name: profile.name, colorHex: profile.color, avatar: profile.avatar, size: 88)
                            Text(verbatim: profile.name)
                                .font(PhoneTheme.display(26, .semibold, relativeTo: .title))
                                .foregroundStyle(BP.ink)
                                .accessibilityIdentifier("account-name")
                        }
                        .padding(.top, 8)
                    }
                    VStack(spacing: 0) {
                        row("Who's watching?", systemImage: "person.2.fill", id: "account-switch-profile") {
                            close()
                            // The sheet leaves first: the stage change would otherwise tear it down mid-dismiss.
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                app.switchProfile()
                            }
                        }
                        // The PIN's tab locks can take Settings away, as on the TV (RoomView).
                        if !parental.hides(Room.settings) {
                            Divider().padding(.leading, 56)
                            link("Settings", systemImage: "gearshape.fill", id: "account-settings") {
                                PhoneSettingsView()
                            }
                        }
                        Divider().padding(.leading, 56)
                        link("Trackers", systemImage: "point.3.connected.trianglepath.dotted", id: "account-trackers") {
                            PhoneTrackersView()
                        }
                        Divider().padding(.leading, 56)
                        NavigationLink(value: PhoneAccountRoute.addons) { linkLabel("Addons", systemImage: "puzzlepiece.extension.fill") }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("account-addons")
                        Divider().padding(.leading, 56)
                        link("About", systemImage: "info.circle.fill", id: "account-about") {
                            EngineStatusView()
                        }
                    }
                    .phoneGlassPlate()
                    .padding(.horizontal, PhoneTheme.margin)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(T("Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T("Done"), action: close).accessibilityIdentifier("account-done")
                }
            }
            .navigationDestination(for: PhoneAccountRoute.self) { route in
                switch route {
                case .addons: PhoneAddonsView()
                }
            }
        }
        // An addon's catalog opens titles, and a title plays from inside the sheet.
        .phonePlayHost(inCover: true)
        .toastHost()
        .presentedCover(Self.presenceId)
        .accessibilityIdentifier("account-sheet")
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(BP.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(T(title)).font(PhoneTheme.sans(17, .medium, relativeTo: .body)).foregroundStyle(BP.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func row(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, systemImage: systemImage) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
    }

    private func link<Destination: View>(_ title: String, systemImage: String, id: String,
                                          @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            linkLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func linkLabel(_ title: String, systemImage: String) -> some View {
        HStack {
            rowLabel(title, systemImage: systemImage)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(BP.inkSubtle)
                .padding(.trailing, 16).accessibilityHidden(true)
        }
    }
}
