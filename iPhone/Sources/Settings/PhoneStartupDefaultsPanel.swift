import SwiftUI

/// Settings → Startup & default, the TV's StartupDefaultsPanel (startup-defaults.tsx): when "Who's
/// watching" asks (profilePromptInterval) and which profile opens at launch (defaultProfileId, any
/// profile without a PIN). The launch and return prompts read both in the engine.
struct PhoneStartupDefaultsPanel: View {
    @EnvironmentObject private var settings: SettingsBridge
    @EnvironmentObject private var profiles: ProfilesStore

    /// startup-defaults.tsx INTERVALS.
    static let intervals: [(value: String, label: String)] = [("launch", "Every launch"), ("15m", "Every 15 min"), ("30m", "Every 30 min"), ("never", "Never")]

    private var interval: String { settings.slice.profilePromptInterval ?? "launch" }
    private var defaultId: String { settings.slice.defaultProfileId ?? "" }

    /// "No default profile", then `profiles.filter((p) => !p.passwordHash)`.
    private var choices: [(id: String, name: String)] {
        [("", T("No default profile"))] + profiles.profiles.filter { $0.passwordHash == nil }.map { ($0.id, $0.name) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(Self.intervals, id: \.value) { option in
                    choice(T(option.label), on: interval == option.value, id: "startup-interval-\(option.value)") {
                        pick("profilePromptInterval", option.value)
                    }
                }
            } header: {
                Text(verbatim: T("Who's watching"))
            } footer: {
                Text(verbatim: T("Choose when Harbor asks you to pick a profile. Timed prompts appear when you return to Harbor."))
            }
            Section {
                ForEach(choices, id: \.id) { option in
                    choice(option.name, on: defaultId == option.id, id: "startup-default-\(option.id.isEmpty ? "none" : option.id)") {
                        pick("defaultProfileId", option.id)
                    }
                }
            } header: {
                Text(verbatim: T("Start as"))
            } footer: {
                Text(verbatim: T("Open this profile at launch. Timed prompts can still appear later. Profiles with a PIN cannot be a default."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Startup & default"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings-startup")
    }

    /// A row with a check on the option in use.
    private func choice(_ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title).foregroundStyle(BP.ink)
                Spacer(minLength: 8)
                if on {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BP.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(id)
    }

    /// startup-defaults.tsx `update({ [key]: value })` for the profile in use.
    private func pick(_ key: String, _ value: String) {
        PhoneFeedback.shared.selection()
        Task { try? await settings.patch([key: .string(value)]) }
    }
}
