import SwiftUI

/// The five places on the iOS 26 tab bar. The TV's twelve rooms fold
/// into them: a tab owns the rooms beside it, which show as chips above its content.
enum PhoneTab: Hashable, CaseIterable {
    case home, discover, live, library, search

    var title: String {
        switch self {
        case .home: return "Home"
        case .discover: return "Discover"
        case .live: return "Live"
        case .library: return "Library"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .discover: return "safari.fill"
        case .live: return "antenna.radiowaves.left.and.right"
        case .library: return "books.vertical.fill"
        case .search: return "magnifyingglass"
        }
    }

    /// The rooms this tab holds, the first one its default. Home is one screen the viewer arranges
    /// (Home/PhoneHomeView.swift): Movies, Shows and Anime are rows added to it, not chips.
    var rooms: [Room] {
        switch self {
        case .home: return [.home]
        case .discover: return [.discover]
        case .live: return [.live, .sports]
        case .library: return [.library, .collections, .calendar]
        case .search: return [.search]
        }
    }

    /// The tab a room is shown under. Settings is not a tab on the phone (the account sheet holds it);
    /// Movies, Shows and Anime are rows on Home.
    static func of(_ room: Room) -> PhoneTab {
        switch room {
        case .home, .movies, .shows, .anime, .settings: return .home
        case .discover: return .discover
        case .live, .sports: return .live
        case .library, .collections, .calendar: return .library
        case .search: return .search
        }
    }
}

/// The words for a Continue Watching entry: the Resume strip above the tab bar and the cards in
/// the Home feed read from the same place.
enum PhoneResume {
    /// "S2E4", or nil for a film.
    static func episodeTag(_ item: ContinueItem) -> String? {
        guard let season = item.season, let episode = item.episode else { return nil }
        return "S\(season)E\(episode)"
    }

    /// Whole minutes left, rounded up; nil when the length is not known.
    static func minutesLeft(_ item: ContinueItem) -> Int? {
        guard item.durationMs > 0 else { return nil }
        let left = max(0, item.durationMs - item.timeOffsetMs)
        return max(1, clampedInt((left / 60_000).rounded(.up)))
    }

    /// "S2E4 · 34 min left", whichever parts are known.
    static func subtitle(_ item: ContinueItem) -> String? {
        var parts: [String] = []
        if let tag = episodeTag(item) { parts.append(tag) }
        if let minutes = minutesLeft(item) { parts.append(T("%lld min left", minutes)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Resume Severance · S2E4 · 34 min left".
    static func accessoryText(_ item: ContinueItem) -> String {
        let lead = T("Resume %@", item.name)
        guard let subtitle = subtitle(item) else { return lead }
        return "\(lead) · \(subtitle)"
    }
}
