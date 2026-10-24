import SwiftUI

/// Settings → Spoilers, the TV's SpoilersPanel (settings/defaults.ts hideSpoilers and the
/// spoilerHide* switches). The masking itself is the engine's (episodeWatched.state / upNextMask),
/// which the phone's episode rows already read; the nested switches show while Blur spoilers is on.
struct PhoneSpoilersPanel: View {
    @EnvironmentObject private var settings: SettingsBridge

    private var hideSpoilers: Bool { settings.slice.hideSpoilers ?? false }

    var body: some View {
        Form {
            Section {
                toggle("Blur spoilers", key: "hideSpoilers", on: hideSpoilers, id: "spoilers-hide")
            } footer: {
                Text(verbatim: T("Hides spoiler-prone episode details in episode lists until you have watched them. Focus a card to reveal it temporarily."))
            }
            if hideSpoilers {
                Section {
                    toggle("Thumbnails", key: "spoilerHideThumbnails", on: settings.slice.spoilerHideThumbnails ?? true, id: "spoilers-thumb")
                    toggle("Titles", key: "spoilerHideTitles", on: settings.slice.spoilerHideTitles ?? true, id: "spoilers-title")
                    toggle("Descriptions", key: "spoilerHideDescriptions", on: settings.slice.spoilerHideDescriptions ?? true, id: "spoilers-desc")
                } header: {
                    Text(verbatim: T("What gets blurred"))
                }
                Section {
                    // Leave the episode you are up to clear and blur only the ones after it.
                    toggle("Keep the next episode visible", key: "spoilerSkipNext", on: settings.slice.spoilerSkipNext ?? true, id: "spoilers-skip-next")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Spoilers"))
        .navigationBarTitleDisplayMode(.inline)
        .motion(.default, value: hideSpoilers)
        .accessibilityIdentifier("settings-spoilers")
    }

    private func toggle(_ label: String, key: String, on: Bool, id: String) -> some View {
        Toggle(isOn: Binding(
            get: { on },
            set: { next in
                PhoneFeedback.shared.selection()
                Task { try? await settings.patch([key: .bool(next)]) }
            }
        )) {
            Text(verbatim: T(label))
        }
        .accessibilityIdentifier(id)
    }
}
