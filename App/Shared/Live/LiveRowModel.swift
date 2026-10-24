import SwiftUI

/// bp-live-row.tsx on Home: the active playlist's ranked channels as guide cells (logo, what's on,
/// progress, what's next); Select tunes the channel. Renders nothing without playlists.
@MainActor
final class LiveRowModel: ObservableObject {
    struct Cell: Decodable, Identifiable {
        var playlistId: String; var channel: LiveModel.Channel; var now: LiveModel.Program?; var next: LiveModel.Program?; var progress: Double?
        var id: String { channel.id }
    }
    struct Row: Decodable { var playlistId: String?; var cells: [Cell] }
    @Published private(set) var cells: [Cell] = []
    @Published private(set) var loaded = false

    func load() async {
        guard !loaded else { return }
        if let r: Row = try? await HarborEngine.shared.call("live.homeRow", []) { cells = r.cells }
        loaded = true
    }

    /// bp-live-cell: nowMs advances at a programme boundary, so a cell never
    /// keeps a programme that has ended. The row was read once per Home visit: a viewer left on
    /// Home saw last hour's show as "now" (with a full bar) until they left the tab. Read again
    /// when a cell's programme has ended, at most once a minute.
    private var lastRefresh = Date.distantPast
    func refreshIfEnded(nowMs: Double) async {
        guard loaded, Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        guard cells.contains(where: { ($0.now?.endMs ?? Double.infinity) <= nowMs }) else { return }
        lastRefresh = Date()
        // A read that comes back empty (the source is reloading) keeps the row under the ring.
        if let r: Row = try? await HarborEngine.shared.call("live.homeRow", []), !r.cells.isEmpty { cells = r.cells }
    }

    func played(_ c: Cell) {
        Task { _ = try? await HarborEngine.shared.callJSON("live.recordPlay", [.string(c.playlistId), .string(c.channel.id)]) }
    }
}
