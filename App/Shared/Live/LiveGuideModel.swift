import SwiftUI

/// The Big Picture guide grid (bp-guide.tsx): a channel column, a half-hour ruler, one gapless
/// lane per channel, a "now" line, and D-pad focus on programme cells. Geometry follows
/// bp-guide-geometry.ts at the TV canvas; the window seeds 60 min before now and grows by
/// 3 h when focus reaches an edge, up to 26 h.
@MainActor
final class LiveGuideModel: ObservableObject {
    struct Cell: Decodable, Identifiable, Equatable {
        var startMs: Double; var endMs: Double; var program: LiveModel.Program?
        var id: String { "\(startMs)" }
    }
    struct Lane: Decodable { var id: String; var catchup: Bool; var cells: [Cell] }

    static let slotMs: Double = 30 * 60_000
    static let pastPadMs: Double = 60 * 60_000
    static let initialWindowMs: Double = 6 * 60 * 60_000
    static let extendMs: Double = 3 * 60 * 60_000
    static let maxWindowMs: Double = 26 * 60 * 60_000

    @Published private(set) var lanes: [String: [Cell]] = [:]
    @Published private(set) var catchup: Set<String> = []
    @Published private(set) var windowStart: Double = 0
    @Published private(set) var windowEnd: Double = 0
    @Published var viewStart: Double = 0

    private var playlistId: String?
    private var channelIds: [String] = []
    private var index: [String: Int] = [:]

    // use-bp-guide-data.ts builds a lane only for a row that is mounted (laneFor, 600 cached).
    // The TV used to ask the engine for every lane of the category at once: "All" on a big
    // playlist is thousands of channels, megabytes of cells over the bridge on every open and
    // on every window extension. Lanes are now fetched for the rows on screen, a batch at a time.
    static let batch = 40
    static let cacheMax = 600
    /// Rows LazyVStack has built (onAppear … onDisappear).
    private var onScreen: Set<String> = []
    /// Lanes being fetched now (so a row coming on screen does not ask twice).
    private var pending: Set<String> = []
    /// Lanes built for an older window or older guide data: shown until the new one lands.
    private var stale: Set<String> = []
    /// Bumped when the playlist or the guide data changes: replies from before are dropped.
    private var epoch = 0

    /// bp-guide.tsx resetKey (`${activeId}:${catKey}`): the list the window was seeded for.
    private var resetKey: String?

    func seed(playlistId: String, channelIds: [String], resetKey: String) async {
        let now = Date().timeIntervalSince1970 * 1000
        if windowStart == 0 || self.resetKey != resetKey {
            // bp-guide.tsx seededRef: another source or chip opens on
            // now again. The window stayed wherever the last chip had been scrolled to (hours
            // ahead, or yesterday), so a new category opened far from what is on.
            let start = (((now - Self.pastPadMs) / Self.slotMs).rounded(.down)) * Self.slotMs
            let end = start + Self.initialWindowMs
            if windowStart != 0, start != windowStart || end != windowEnd { stale = Set(lanes.keys) }
            windowStart = start
            windowEnd = end
            viewStart = start
        }
        self.resetKey = resetKey
        if self.playlistId != playlistId { epoch += 1; pending = [] }
        let changedList = self.playlistId != playlistId || self.channelIds != channelIds
        self.playlistId = playlistId
        self.channelIds = channelIds
        if changedList {
            var idx: [String: Int] = [:]
            for (i, id) in channelIds.enumerated() where idx[id] == nil { idx[id] = i }
            index = idx
            // Rows that are still listed keep their lanes (no empty frame); the rest go.
            lanes = lanes.filter { idx[$0.key] != nil }
            catchup = catchup.filter { idx[$0] != nil }
            stale = stale.filter { idx[$0] != nil }
        }
        await fill(from: 0)
        await fillOnScreen()
    }

    func rowAppeared(_ id: String) {
        onScreen.insert(id)
        guard needsLane(id), !pending.contains(id), let i = index[id] else { return }
        Task { await fill(from: i) }
    }

    func rowDisappeared(_ id: String) { onScreen.remove(id) }

    private func needsLane(_ id: String) -> Bool { lanes[id] == nil || stale.contains(id) }

    /// This row's lane and the next rows' (the ones D-pad Down reaches next).
    private func fill(from i: Int) async {
        guard i >= 0, i < channelIds.count else { return }
        let ids = channelIds[i..<min(channelIds.count, i + Self.batch)].filter { needsLane($0) && !pending.contains($0) }
        await fetch(Array(ids))
    }

    private func fillOnScreen() async {
        await fetch(channelIds.filter { onScreen.contains($0) && needsLane($0) && !pending.contains($0) })
    }

    /// One `live.lanes` ask for the current window. A reply for an older window asks again for
    /// the rows still on screen; a reply from before a playlist or guide change is dropped.
    private func fetch(_ ids: [String]) async {
        guard let playlistId, !ids.isEmpty else { return }
        let mine = epoch, start = windowStart, end = windowEnd
        pending.formUnion(ids)
        let out: [Lane]? = try? await HarborEngine.shared.call("live.lanes", [playlistId, ids, start, end])
        guard mine == epoch else { return }
        pending.subtract(ids)
        guard start == windowStart, end == windowEnd else {
            await fetch(ids.filter { onScreen.contains($0) && needsLane($0) && !pending.contains($0) })
            return
        }
        guard let out else { return }
        var next = lanes
        var replay = catchup
        for l in out {
            next[l.id] = l.cells
            stale.remove(l.id)
            if l.catchup { replay.insert(l.id) } else { replay.remove(l.id) }
        }
        if next.count > Self.cacheMax {
            // laneFor's cache clears at 600; rows off screen are rebuilt when they come back.
            next = next.filter { onScreen.contains($0.key) }
            stale = stale.filter { next[$0] != nil }
        }
        lanes = next
        catchup = replay
    }

    /// bp-guide.tsx extendWindow / extendWindowBack: the window grows now; the lanes on screen
    /// are rebuilt for the new span and keep their old cells until the new ones arrive, so focus
    /// never lands on nothing. Rows off screen are rebuilt when they come back.
    func extend(forward: Bool) async {
        guard windowEnd - windowStart < Self.maxWindowMs else { return }
        var start = windowStart, end = windowEnd
        if forward { end = min(end + Self.extendMs, start + Self.maxWindowMs) }
        else { start = max(start - Self.extendMs, end - Self.maxWindowMs) }
        windowStart = start
        windowEnd = end
        stale = Set(lanes.keys)
        await fillOnScreen()
    }

    /// The guide data changed under the lanes (it finished loading, or the short EPG landed).
    func reloadAll() async {
        epoch += 1
        pending = []
        stale = Set(lanes.keys)
        await fillOnScreen()
        await fill(from: 0)
    }

    /// A manual EPG match changed one channel: rebuild its lane, keep every other one.
    func refresh(_ id: String) async {
        stale.insert(id)
        pending.remove(id)
        await fetch([id])
    }

    /// viewStartFor: pan so the focused cell is visible; a cell wider than the view pins to its start.
    func reveal(cellStart: Double, cellEnd: Double, visibleMs: Double) {
        let last = max(windowStart, windowEnd - visibleMs)
        var next = viewStart
        if cellStart < viewStart { next = cellStart }
        else if cellEnd > viewStart + visibleMs { next = min(cellStart, cellEnd - visibleMs) }
        viewStart = min(max(next, windowStart), last)
    }
}
