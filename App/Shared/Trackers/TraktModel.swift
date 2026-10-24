import SwiftUI

/// Device-code / PIN sign-in for Trakt (lib/trakt/device-auth.ts) and Simkl (lib/simkl/device-auth.ts):
/// show a code, the viewer types it on a phone, we poll until the service says yes.
@MainActor
final class TraktModel: ObservableObject {
    /// Engine export prefix ("trakt" or "simkl") and the display name.
    let service: String
    let label: String
    init(service: String = "trakt", label: String = "Trakt") { self.service = service; self.label = label }

    /// `reconnect`: a session is stored but its token expired or could not be renewed (Harbor's
    /// token proxy is gone). The tokens are kept, never signed out for it. Simkl does not send it.
    struct Status: Decodable { var authenticated: Bool; var username: String?; var reconnect: Bool? }
    struct Code: Decodable { var deviceCode: String; var userCode: String; var verificationUrl: String; var expiresIn: Double; var pollIntervalSec: Double }
    struct Poll: Decodable { var kind: String; var message: String?; var username: String? }

    @Published private(set) var status = Status(authenticated: false, username: nil)
    @Published private(set) var code: Code?
    @Published private(set) var note: String?
    /// Whether `note` reports a success (tinted live, not danger); set with it, as LetterboxdPanel
    /// does, so a translated "Connected as …" keeps its colour.
    @Published private(set) var noteOk = false
    private var pollTask: Task<Void, Never>?
    private var connectGen = 0

    func refresh() async {
        status = (try? await HarborEngine.shared.call("\(service).status", [])) ?? Status(authenticated: false, username: nil)
    }

    private func say(_ text: String?, ok: Bool = false) {
        note = text
        noteOk = ok
    }

    /// trakt-device-modal.tsx / simkl-device-modal.tsx success line: "Connected as @{username}"
    /// (Trakt) or "Connected as {username}" (Simkl), else "Connected to Trakt" / "Connected to Simkl".
    private func connectedNote(_ username: String?) -> String {
        guard let u = username, !u.isEmpty else { return T("Connected to %@", label) }
        return service == "trakt" ? T("Connected as @%@", u) : T("Connected as %@", u)
    }

    /// trakt-device-modal.tsx / simkl-device-modal.tsx "Code expired" message (upstream's key).
    private static var expiredNote: String { T("The authorization code timed out before you finished. Try again.") }

    /// trakt-device-modal.tsx "Access denied" message. Simkl's modal has no denied state, so its
    /// line stays the TV's own, as a format key a future catalog can pick up.
    private var deniedNote: String {
        service == "trakt" ? T("Trakt reported that authorization was denied. Try again if this was unintentional.") : T("%@ said no.", label)
    }

    func connect() async {
        say(nil)
        connectGen &+= 1
        let gen = connectGen
        do {
            let c: Code = try await HarborEngine.shared.call("\(service).deviceCode", [])
            // The panel closed (cancelConnect) or Connect was pressed again while the
            // code was being fetched: this code's poll would run unseen until it expired.
            guard gen == connectGen else { return }
            code = c
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(c.expiresIn)
                var interval = max(3, c.pollIntervalSec)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(for: .seconds(interval))
                    guard let self, !Task.isCancelled else { return }
                    let r: Poll = (try? await HarborEngine.shared.call("\(self.service).poll", [c.deviceCode])) ?? Poll(kind: "error", message: "poll failed", username: nil)
                    guard !Task.isCancelled, self.code?.deviceCode == c.deviceCode else { return }
                    switch r.kind {
                    case "authorized":
                        self.code = nil
                        await self.refresh()
                        self.say(self.connectedNote(r.username ?? self.status.username), ok: true)
                        return
                    case "slow_down": interval += 2
                    case "expired": self.code = nil; self.say(TraktModel.expiredNote); return
                    case "denied": self.code = nil; self.say(self.deniedNote); return
                    case "error": self.say(r.message)
                    default: break
                    }
                }
                // The code's own lifetime ran out without a verdict (Simkl never says "expired").
                guard let self, !Task.isCancelled, self.code?.deviceCode == c.deviceCode else { return }
                self.code = nil
                self.say(TraktModel.expiredNote)
            }
        } catch {
            // The engine's own line ("Trakt sign-in is unavailable: …"): an EngineError's
            // localizedDescription is only "The operation couldn't be completed".
            let text = "\(error)".replacingOccurrences(of: "JS error: ", with: "")
            say(text.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "") ?? T("Sign-in failed."))
        }
    }

    /// trakt-device-modal.tsx / simkl-device-modal.tsx: closing the panel before the
    /// code is confirmed calls cancelConnect (provider.tsx cancels the poll). The poll kept running
    /// until the code expired while the panel stayed alive off screen.
    func cancelConnect() {
        connectGen &+= 1
        pollTask?.cancel()
        pollTask = nil
        code = nil
    }

    func disconnect() async {
        pollTask?.cancel(); code = nil
        // The last "Connected as …" stayed up under "Not connected".
        say(nil)
        // simkl-panel.tsx: Simkl's disconnect also resets the profile's Simkl settings (engine/simkl.ts).
        let p = ProfilesStore.shared.active
        let args: [AnyJSON] = service == "simkl" ? [.string(p?.id ?? "default"), .bool(p?.linked ?? true)] : []
        _ = try? await HarborEngine.shared.callJSON("\(service).disconnect", args)
        await refresh()
    }
}
