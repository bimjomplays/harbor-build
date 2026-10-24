import SwiftUI

/// Settings → Home servers (lib/media-server): Plex through the plex.tv/link PIN, Jellyfin and
/// Emby through address + credentials; each connection can be indexed, disabled or removed.
@MainActor
final class HomeServersModel: ObservableObject {
    struct Connection: Decodable, Identifiable {
        struct Summary: Decodable { var at: Double; var movies: Int; var shows: Int; var episodes: Int }
        struct SyncResult: Decodable { var ok: Bool; var message: String; var at: Double }
        var id: String; var provider: String; var name: String; var origin: String; var enabled: Bool
        var lastSyncAt: Double?; var lastSummary: Summary?; var lastSyncResult: SyncResult?
        var preferredQuality: String?; var refreshInterval: String?
        /// home-servers-tab.tsx "Every… N days" (refreshInterval "custom"), set on the desktop.
        var refreshEveryDays: Double?
    }
    struct Pin: Decodable { var pinId: Int; var code: String; var url: String; var expiresAt: Double }
    struct Poll: Decodable { struct Server: Decodable, Identifiable { var id: String; var name: String; var owned: Bool; var available: Bool; var origin: String }; var kind: String; var servers: [Server]? }
    struct Progress: Decodable { var connectionId: String; var active: Bool; var message: String }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var pin: Pin?
    @Published private(set) var servers: [Poll.Server] = []
    @Published private(set) var progress: [String: String] = [:]
    @Published private(set) var note: String?
    /// Set with `note` (say): true only for the "Indexed …" sync line. The panel colours the note by
    /// this, not by its wording.
    @Published private(set) var noteOk = false
    @Published private(set) var busy = false
    private var pollTask: Task<Void, Never>?
    private var unsubscribe: (() -> Void)?

    deinit { pollTask?.cancel(); unsubscribe?() }

    func load() async {
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard type == "harbor:media-server-sync", let p = detail.flatMap({ try? $0.decode(Progress.self) }) else { return }
                if p.active { self?.progress[p.connectionId] = p.message } else { self?.progress[p.connectionId] = nil; Task { await self?.load() } }
            }
        }
        connections = (try? await HarborEngine.shared.call("homeServers.connections", [])) ?? []
    }

    // Plex: mint a PIN, show it, poll until approved, then let the viewer pick a server.
    func startPlex() async {
        note = nil; servers = []
        do {
            let p: Pin = try await HarborEngine.shared.call("homeServers.plexPinStart", [])
            pin = p
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled, let pin = self.pin else { return }
                    guard let r: Poll = try? await HarborEngine.shared.call("homeServers.plexPinPoll", [pin.pinId]) else { continue }
                    switch r.kind {
                    case "authorized":
                        self.servers = r.servers ?? []
                        if self.servers.isEmpty { self.say("Plex signed in, but that account has no servers."); self.pin = nil }
                        return
                    case "expired": self.pin = nil; self.say("That code expired. Try again."); return
                    default: break
                    }
                }
            }
        } catch { say(T("Plex sign-in failed: %@", error.localizedDescription)) }
    }

    func addPlex(_ server: Poll.Server) async {
        guard let pin, !busy else { return }
        busy = true; defer { busy = false }
        struct Out: Decodable { var id: String }
        if let c: Out = try? await HarborEngine.shared.call("homeServers.plexAdd", [pin.pinId, server.id]) {
            self.pin = nil; servers = []
            await load()
            await sync(c.id)
        } else { say("Couldn't save that Plex server.") }
    }

    /// Sets the note and its ok flag together (LetterboxdPanel / TraktView noteOk pattern).
    private func say(_ text: String, ok: Bool = false) { note = text; noteOk = ok }

    func cancelPlex() { pollTask?.cancel(); pin = nil; servers = [] }

    func connect(provider: String, address: String, username: String, password: String) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        note = nil
        struct Out: Decodable { var id: String }
        do {
            let c: Out = try await HarborEngine.shared.call("homeServers.connect", [provider, address, username, password])
            await load()
            await sync(c.id)
            return true
        } catch {
            let line: String? = "\(error)".split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "")
            say(line ?? "Couldn't connect.")
            return false
        }
    }

    func sync(_ id: String) async {
        struct Out: Decodable { var libraries: Int; var itemCount: Int; var removedItems: Int }
        progress[id] = "Connecting…"
        do {
            let o: Out = try await HarborEngine.shared.call("homeServers.sync", [id])
            say(T("Indexed %lld items from %lld libraries.", o.itemCount, o.libraries), ok: true)
        } catch {
            let line: String = "\(error)".split(separator: "\n").first.map(String.init) ?? ""
            say(T("Sync failed: %@", line))
        }
        progress[id] = nil
        await load()
    }

    func remove(_ id: String) async {
        _ = try? await HarborEngine.shared.callJSON("homeServers.remove", [.string(id)])
        await load()
    }

    func toggle(_ c: Connection) async {
        _ = try? await HarborEngine.shared.callJSON("homeServers.update", [.string(c.id), .object(["enabled": .bool(!c.enabled)])])
        await load()
    }

    // home-servers-tab.tsx pickers, as cycling buttons.
    static let qualities: [(String, String)] = [("original", "Original"), ("4k-40", "4K · 40 Mbps"), ("1080p-20", "1080p · 20 Mbps"), ("1080p-12", "1080p · 12 Mbps"), ("720p-4", "720p · 4 Mbps"), ("480p-2", "480p · 2 Mbps"), ("360p-0.7", "360p · 0.7 Mbps")]
    static let intervals: [(String, String)] = [("launch", "Every launch"), ("daily", "Daily"), ("three-days", "Every 3 days"), ("weekly", "Weekly"), ("manual", "Manual")]

    func cycle(_ c: Connection, field: String, options: [(String, String)], current: String?) async {
        let at = options.firstIndex { $0.0 == current } ?? 0
        let next = options[(at + 1) % options.count].0
        _ = try? await HarborEngine.shared.callJSON("homeServers.update", [.string(c.id), .object([field: .string(next)])])
        await load()
    }
}
