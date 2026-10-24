import SwiftUI

/// The shell for a kid profile. The kids' home is a later stage, and until it exists a kid sees no
/// catalogue at all (nothing from the adult feeds), only a greeting and the way out: a grown-up's
/// PIN, when the profile has one. Links wait in the queue meanwhile (titles for the kids' detail
/// page, everything else for an adult shell), and the curfew cover still goes over this view.
struct PhoneKidsShell: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var askingPin = false

    private var kid: ProfilesStore.Profile? { profiles.active }
    private var parentPinHash: String? { kid?.kid?.parentPinHash }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0b3a5c), Color(hex: 0x0a7d9c)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                if let kid {
                    ProfileFace(name: kid.name, colorHex: kid.color, avatar: kid.avatar, size: 112)
                    Text(T("Hi %@!", kid.name))
                        .font(PhoneTheme.display(40, .semibold, relativeTo: .largeTitle))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("kids-greeting")
                }
                Text(T("Harbor Kids is coming to iPhone in a later release."))
                    .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                Spacer()
                Button(T("Grown-ups")) {
                    if parentPinHash != nil { askingPin = true } else { app.switchProfile() }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("kids-exit")
            }
            .padding(32)
        }
        .onAppear { ParentalGate.shared.attach() }
        .sheet(isPresented: $askingPin) {
            PhonePinPad(title: T("Parent PIN"),
                        subtitle: T("Enter the 4-digit parent PIN to continue."),
                        cooldownKey: "parent-\(kid?.id ?? "")",
                        verify: { entry in parentPinHash.map { ProfilesStore.hashPin(entry) == $0 } ?? false },
                        finish: { ok in
                            askingPin = false
                            if ok {
                                Task {
                                    try? await Task.sleep(for: .milliseconds(350))
                                    app.switchProfile()
                                }
                            }
                        })
                .presentationDetents([.large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kids-shell")
    }
}
