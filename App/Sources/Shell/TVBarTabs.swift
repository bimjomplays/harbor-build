import SwiftUI

extension Room {
    /// Rooms that are no longer Apple TV top-bar tabs. They open from
    /// Library → Browse instead. The iPhone's strip keeps them through `shellTabs`.
    static let offTVBar: [Room] = [.anime, .shows, .movies]

    /// The Apple TV top bar: `shellTabs` (the viewer's order, hidden tabs, locks) without
    /// Anime, Shows and Movies, even when a saved layout lists them.
    @MainActor static func tvBar(sportsDeclined: Bool, gate: ParentalGate, nav: SettingsBridge.NavLayout?) -> [Room] {
        shellTabs(sportsDeclined: sportsDeclined, gate: gate, nav: nav).filter { !offTVBar.contains($0) }
    }

    /// Library → Browse: the rooms that left the bar, minus any a profile lock hides.
    @MainActor static func browsable(gate: ParentalGate) -> [Room] {
        offTVBar.filter { !gate.hides($0) }
    }
}
