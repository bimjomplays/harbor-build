import SwiftUI

/// Settings → Letterboxd (settings/letterboxd-panel.tsx, public mode): a Letterboxd username is
/// checked against Stremboxd and turns on the Library's Letterboxd tab (the watchlist) and the
/// Letterboxd rows on Movies. Full mode (password sign-in) stays on the desktop app.
@MainActor
final class LetterboxdModel: ObservableObject {
    struct Status: Decodable { var enabled: Bool; var mode: String; var username: String; var active: Bool; var fullConnected: Bool }
    struct Connect: Decodable { var ok: Bool; var catalogs: Int; var message: String? }

    @Published private(set) var status: Status?
    @Published private(set) var note: String?
    @Published private(set) var noteOk = false
    @Published private(set) var busy = false

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    func refresh() async {
        let p = profile
        status = try? await HarborEngine.shared.call("letterboxd.status", [p.id, p.linked])
    }

    /// letterboxd-panel handleVerify.
    func connect(_ username: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let p = profile
        do {
            let r: Connect = try await HarborEngine.shared.call("letterboxd.connect", [p.id, p.linked, username])
            noteOk = r.ok
            note = r.ok ? T("Connected. %lld catalogs are available.", r.catalogs) : (r.message ?? "Could not reach Stremboxd. Check your connection.")
        } catch {
            noteOk = false
            note = "Could not reach Stremboxd. Check your connection."
        }
        await refresh()
    }

    /// "Enable Letterboxd integration" switched off.
    func disable() async {
        let p = profile
        _ = try? await HarborEngine.shared.callJSON("letterboxd.disable", [.string(p.id), .bool(p.linked)])
        note = nil
        await refresh()
    }
}
