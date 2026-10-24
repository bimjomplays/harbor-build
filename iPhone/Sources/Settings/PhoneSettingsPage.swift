import SwiftUI

/// Every page Settings lists, under the TV's section names. The root
/// (PhoneSettingsView) only lists them; what each one opens is decided in `destination` below, so a
/// a page that gets built later changes its own case there and nothing in the root.
enum PhoneSettingsPage: String, Hashable, CaseIterable, Identifiable {
    case appearance, tabs, homeRows, animeRows, spoilers
    case player, streamPriority, subtitles, anime4k
    case stremio, trackers, tmdb, homeServers, aiSearch
    case profiles, startup
    case about

    var id: String { rawValue }

    /// The TV's section name (SettingsView / BPSettingsView).
    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .tabs: return "Tabs"
        case .homeRows: return "Home rows"
        case .animeRows: return "Anime rows"
        case .spoilers: return "Spoilers"
        case .player: return "Player"
        case .streamPriority: return "Stream priority"
        case .subtitles: return "Subtitles"
        case .anime4k: return "Anime4K"
        case .stremio: return "Stremio"
        case .trackers: return "Trackers"
        case .tmdb: return "TMDB"
        case .homeServers: return "Home servers"
        case .aiSearch: return "AI search"
        case .profiles: return "Profiles"
        case .startup: return "Startup & default"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintpalette.fill"
        case .tabs: return "rectangle.split.3x1.fill"
        case .homeRows: return "house.fill"
        case .animeRows: return "sparkles.tv.fill"
        case .spoilers: return "eye.slash.fill"
        case .player: return "play.rectangle.fill"
        case .streamPriority: return "arrow.up.arrow.down.circle.fill"
        case .subtitles: return "captions.bubble.fill"
        case .anime4k: return "wand.and.stars"
        case .stremio: return "person.crop.circle.fill"
        case .trackers: return "checklist"
        case .tmdb: return "film.stack.fill"
        case .homeServers: return "server.rack"
        case .aiSearch: return "sparkle.magnifyingglass"
        case .profiles: return "person.2.fill"
        case .startup: return "power.circle.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// The root's groups, top to bottom.
    static let groups: [(title: String, pages: [PhoneSettingsPage])] = [
        ("Look & feel", [.appearance, .tabs, .homeRows, .animeRows, .spoilers]),
        ("Playback", [.player, .streamPriority, .subtitles, .anime4k]),
        ("Accounts & services", [.stremio, .trackers, .tmdb, .homeServers, .aiSearch]),
        ("Profiles", [.profiles, .startup]),
        ("About", [.about]),
    ]

    /// The page a row opens. A page not built yet is a placeholder until it lands.
    /// Player was moved here from the account sheet.
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .appearance: PhoneAppearancePanel()
        case .tabs: PhoneTabsPanel()
        case .homeRows: PhoneHomeRowsPanel()
        case .animeRows: PhoneAnimeRowsPanel()
        case .spoilers: PhoneSpoilersPanel()
        case .player: PhonePlayerSettingsView()
        case .profiles: PhoneProfilesSettingsView()
        case .streamPriority: PhoneStreamPriorityPanel()
        case .subtitles: PhoneSubtitlesPanel()
        case .anime4k: PhoneAnime4KPanel()
        case .stremio: PhoneStremioPanel()
        case .trackers: PhoneTrackersView()
        case .tmdb: PhoneTmdbPanel()
        case .homeServers: PhoneHomeServersPanel()
        case .aiSearch: PhoneAISearchPanel()
        case .startup: PhoneStartupDefaultsPanel()
        case .about: PhoneAboutView()
        }
    }
}

/// A page whose settings arrive with a later stage of Harbor for iPhone.
struct PhoneSettingsPlaceholder: View {
    let page: PhoneSettingsPage

    var body: some View {
        ScrollView {
            EmptyState(title: T(page.title),
                       message: T("This part of Harbor for iPhone arrives in a later release."),
                       systemImage: page.icon)
                .padding(.top, 60)
        }
        .background(PhoneBackground())
        .navigationTitle(T(page.title))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings-soon-\(page.rawValue)")
    }
}
