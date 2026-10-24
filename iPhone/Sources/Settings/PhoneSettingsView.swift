import SwiftUI

/// Settings, pushed from the account sheet: a grouped Form listing every
/// section the TV has, under its names. Everything is saved for the active profile, through the same
/// stores the TV uses (SettingsBridge, ThemeStore, the engine's row and tab editors). The pages are
/// in PhoneSettingsPage; this view only lists them.
struct PhoneSettingsView: View {
    @EnvironmentObject private var settings: SettingsBridge
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var external = PhoneExternalPlay.shared
    @AppStorage(PlayerSession.anime4kKey) private var anime4k = "off"

    var body: some View {
        Form {
            ForEach(PhoneSettingsPage.groups, id: \.title) { group in
                let pages: [PhoneSettingsPage] = group.pages.filter(shows)
                if !pages.isEmpty {
                    Section {
                        ForEach(pages) { page in
                            // Destination links: a value link on a page that a view link pushed is never
                            // matched to its navigationDestination.
                            NavigationLink { page.destination } label: { row(page) }
                                .accessibilityIdentifier("settings-row-\(page.rawValue)")
                        }
                    } header: {
                        Text(verbatim: T(group.title))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(BP.accent)
        // A `--fixtures` launch skips both reads at boot; Settings shows what the profile has saved.
        .task {
            if !settings.loaded { await settings.load() }
            if theme.state == nil { await theme.load() }
        }
        // The Player row names a player only while it is installed.
        .onAppear { external.refresh() }
        .accessibilityIdentifier("settings-root")
    }

    /// Startup & default only when there is more than one profile (StartupDefaultsPanel, as upstream).
    private func shows(_ page: PhoneSettingsPage) -> Bool {
        page != .startup || profiles.profiles.count > 1
    }

    private func row(_ page: PhoneSettingsPage) -> some View {
        HStack(spacing: 14) {
            Image(systemName: page.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(BP.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(verbatim: T(page.title))
                .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
            Spacer(minLength: 8)
            if let value = value(page) {
                Text(verbatim: value)
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                    .foregroundStyle(.secondary)
                    .lines(1)
            }
        }
    }

    /// What a row is set to now, where one word says it.
    private func value(_ page: PhoneSettingsPage) -> String? {
        switch page {
        case .appearance:
            guard let s = theme.state else { return nil }
            return s.presets.first(where: { $0.id == s.active })?.name
        case .spoilers:
            return T((settings.slice.hideSpoilers ?? false) ? "On" : "Off")
        case .player:
            return external.preferred?.name ?? "Harbor"
        case .profiles:
            return "\(profiles.profiles.count)"
        case .subtitles:
            return PhoneSubtitlesPanel.summary(settings.slice.preferredSubLangs)
        case .anime4k:
            return T(anime4k == "off" ? "Off" : "On")
        case .stremio:
            return PhoneStremioPanel.summary(profiles)
        case .tmdb:
            return PhoneTmdbPanel.summary(key: settings.slice.tmdbKey, rejected: TmdbHealth.shared.rejected)
        case .startup:
            return PhoneStartupDefaultsPanel.intervals.first { $0.value == (settings.slice.profilePromptInterval ?? "launch") }.map { T($0.label) }
        case .about:
            return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        default:
            return nil
        }
    }
}
