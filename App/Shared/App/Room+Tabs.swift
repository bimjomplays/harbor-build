import SwiftUI
import UIKit

extension Room {
    /// bp-top-bar.tsx visibleTabs: the tab strip and the shoulder cycle both read this, so a tab
    /// can never be hidden from one and reachable through the other. `nav` is the
    /// viewer's tab editing (engine/navEdit.ts over settings.navCustomization, chrome/nav-items.tsx
    /// applyNavCustomization): its order, and the tabs it hides, which now include the retired
    /// "Hide Live TV" switch (settings/load.ts _navHideMigrateV1). A hidden tab
    /// leaves the bar only; the room still opens from Settings, Search or a deep link, as a hidden
    /// sidebar entry does upstream.
    @MainActor static func shellTabs(sportsDeclined: Bool, gate: ParentalGate, nav: SettingsBridge.NavLayout?) -> [Room] {
        let hidden = Set(nav?.hidden ?? [])
        return arranged(nav).filter {
            !(sportsDeclined && $0 == .sports)
                && !hidden.contains($0.rawValue) && !gate.hides($0)
        }
    }

    /// Room.tabs in the viewer's order; a tab the layout does not name keeps its default place at the end.
    static func arranged(_ nav: SettingsBridge.NavLayout?) -> [Room] {
        guard let nav else { return tabs }
        var out: [Room] = []
        for raw in nav.order {
            if let r = Room(rawValue: raw), tabs.contains(r), !out.contains(r) { out.append(r) }
        }
        for r in tabs where !out.contains(r) { out.append(r) }
        return out
    }

    /// engine/navEdit.ts `editable`: a tab with a NavItemId that is not pinned. Home stays first and
    /// shown (Back lands there); Search is a Big Picture tab with no sidebar entry.
    var navEditable: Bool { self != .home && self != .search && self != .settings }
}
