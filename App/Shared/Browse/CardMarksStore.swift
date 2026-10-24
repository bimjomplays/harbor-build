import Foundation
import Combine
import SwiftUI

/// Per-card marks from the engine (`cards.marks`, bp-card-marks + bp-card-state-marks):
/// the identity chip, watchlist bookmark, watched check and the Top 10 ribbon.
struct CardMarks: Decodable, Equatable {
    var id: String
    var chip: String?
    var bookmark: String?      // topStart | topEnd | bottomEnd | bottomStart
    var watched: String?       // topEnd | bottomEnd
    var top10: String?         // left | right
}

/// One process-wide table keyed by meta id. Screens ask for their visible metas after a load;
/// tiles read it directly, so a mark that changes (watched, bookmarked) updates everywhere.
@MainActor
final class CardMarksStore: ObservableObject {
    static let shared = CardMarksStore()

    @Published private(set) var byId: [String: CardMarks] = [:]
    private var lastMetas: [Meta] = []

    private struct CardMeta: Encodable {
        var id: String; var type: String; var name: String
        var releaseInfo: String?; var releaseDate: String?; var inTheaters: Bool?
        init(_ m: Meta) { id = m.id; type = m.type; name = m.name; releaseInfo = m.releaseInfo; releaseDate = m.releaseDate; inTheaters = m.inTheaters }
    }

    /// The profile the table was read for (nil until the first read, and after a switch).
    private var tableProfile: String?
    private var bag = Set<AnyCancellable>()

    init() {
        // Cleared the moment the profile changes, before any screen of the
        // new profile draws a tile.
        ProfilesStore.shared.$activeId.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.tableProfile = nil
            if !self.byId.isEmpty { self.byId = [:] }
        }.store(in: &bag)
    }

    func refresh(_ metas: [Meta]) async {
        guard !Fixtures.active, !metas.isEmpty else { return }
        lastMetas = metas
        let p = ProfilesStore.shared.active
        let pid = p?.id ?? "default"
        // The table is per profile: after a switch the previous profile's
        // watched checks and bookmarks stayed on every card (Home's cached shelves show before the
        // live build re-marks them, and titles not on screen kept theirs for the whole session).
        if tableProfile != pid {
            tableProfile = pid
            if !byId.isEmpty { byId = [:] }
        }
        guard let list: [CardMarks] = try? await HarborEngine.shared.call("cards.marks", [metas.map(CardMeta.init), pid, p?.linked ?? true]) else { return }
        // A read started for the previous profile answers after the switch: not this profile's marks.
        guard tableProfile == pid else { return }
        // Every BPTileView observes this store: republishing an unchanged table (each room
        // load, Home's re-reads, every cover close via remark()) redrew every tile on screen.
        var next = byId
        var changed = false
        for m in list where next[m.id] != m { next[m.id] = m; changed = true }
        if changed { byId = next }
    }

    /// Re-read the Stremio library into the watchlist aggregate, then re-mark the last screen.
    func refreshWatchlist() async {
        guard !Fixtures.active else { return }
        let key = ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        _ = try? await HarborEngine.shared.callJSON("cards.refreshWatchlist", [key.map { .string($0) } ?? .null])
        await refresh(lastMetas)
    }

    /// Something local changed (a title finished, a bookmark toggled): recompute the last screen.
    func remark() async { await refresh(lastMetas) }
}
