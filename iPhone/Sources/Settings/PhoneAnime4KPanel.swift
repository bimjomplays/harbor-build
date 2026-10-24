import SwiftUI

/// Settings → Anime4K, the TV's Anime4KPanel (settings/defaults.ts playerAnime4k*): on or off, the
/// mode, the on-screen indicator and the one-time shader download. As on the TV, on/off and a picked
/// mode are this device's own choice (PlayerSession.anime4kKey: "off", "auto" or a mode, never
/// synced; the player's Anime4K menu writes the same key), so a desktop profile's HQ setting never
/// runs on a phone by itself. "On" is Auto: anime only, in the profile's mode.
struct PhoneAnime4KPanel: View {
    @EnvironmentObject private var settings: SettingsBridge
    @ObservedObject private var store = Anime4KStore.shared
    @AppStorage(PlayerSession.anime4kKey) private var choice = "off"

    static let modes = ["A", "B", "C", "AA", "BB", "CA"]

    private var on: Bool { choice != "off" }
    private var indicator: Bool { settings.slice.playerAnime4kIndicator ?? true }
    /// The mode in use: this device's own pick when it holds one, else the mode Auto uses.
    private var mode: String { Self.modes.contains(choice) ? choice : (settings.slice.playerAnime4kMode ?? "A") }

    /// "A+A" for the two-pass modes ("AA"), as the TV's chips read.
    static func modeLabel(_ m: String) -> String { m.count == 2 ? "\(m.prefix(1))+\(m.suffix(1))" : m }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { on }, set: { next in
                    PhoneFeedback.shared.selection()
                    choice = next ? "auto" : "off"
                })) {
                    Text(verbatim: T("Anime4K"))
                }
                .accessibilityIdentifier("anime4k-on")
                Toggle(isOn: Binding(get: { indicator }, set: { next in
                    PhoneFeedback.shared.selection()
                    Task { try? await settings.patch(["playerAnime4kIndicator": .bool(next)]) }
                })) {
                    Text(verbatim: T("Indicator"))
                }
                .accessibilityIdentifier("anime4k-indicator")
            } footer: {
                Text(verbatim: T("Real-time anime upscaling and restoration through mpv shaders (bloc97/Anime4K). On runs on anime only, in the mode below; the player's Anime4K menu picks one for a single title."))
            }
            Section {
                ForEach(Self.modes, id: \.self) { m in
                    PhoneChoiceRow(title: Self.modeLabel(m), on: mode == m, id: "anime4k-mode-\(m)") {
                        PhoneFeedback.shared.selection()
                        if Self.modes.contains(choice) {
                            choice = m
                        } else {
                            Task { try? await settings.patch(["playerAnime4kMode": .string(m)]) }
                        }
                    }
                }
            } header: {
                Text(verbatim: T("Mode"))
            }
            Section {
                Button {
                    guard !store.busy else { return }
                    PhoneFeedback.shared.selection()
                    Task { await store.ensure(force: store.installed) }
                } label: {
                    HStack {
                        Text(verbatim: store.busy ? T("Downloading…") : (store.installed ? T("Re-download shaders") : T("Download shaders")))
                        Spacer(minLength: 8)
                        if store.busy { ProgressView() }
                    }
                }
                .accessibilityIdentifier("anime4k-download")
                if let note = store.note { PhoneSettingsNote(text: T(note), ok: store.noteOk) }
            } header: {
                Text(verbatim: T("Shaders"))
            } footer: {
                Text(verbatim: store.installed ? T("Shaders installed") : T("Not downloaded yet (about 3 MB, fetched on first use too)"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Anime4K"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings-anime4k")
    }
}
