import SwiftUI
import CoreImage.CIFilterBuiltins

/// AniList / MyAnimeList sign-in for a television: the authorize link as text and a QR code,
/// the viewer signs in on a phone and pastes the code back (the tvOS keyboard accepts a paste
/// from the iPhone remote), then upstream exchanges it through Harbor's token proxy.
@MainActor
final class PasteTrackerModel: ObservableObject {
    /// `reconnect`: a session is stored but expired or its renewal failed; it is kept.
    struct Status: Decodable { var authenticated: Bool; var username: String?; var reconnect: Bool? }
    let service: String   // "anilist" | "mal"
    let label: String
    @Published private(set) var status = Status(authenticated: false, username: nil)
    @Published private(set) var url: String?
    @Published private(set) var note: String?
    /// Whether `note` reports a success; set with it (LetterboxdPanel), so the tint no longer
    /// depends on the English wording.
    @Published private(set) var noteOk = false
    @Published private(set) var busy = false

    init(service: String, label: String) { self.service = service; self.label = label }

    func refresh() async {
        status = (try? await HarborEngine.shared.call("\(service).status", [])) ?? Status(authenticated: false, username: nil)
    }

    func begin() async {
        note = nil
        noteOk = false
        // The code exchange goes through Harbor's token proxy: when it is gone, say so here
        // rather than after the viewer has signed in on the phone.
        if let blocked: String = try? await HarborEngine.shared.call("\(service).signInBlocked", []) {
            note = blocked
            return
        }
        url = try? await HarborEngine.shared.call("\(service).authorizeUrl", [])
        if url == nil { note = "Couldn't build the sign-in link." }
    }

    /// Whether the code was accepted.
    func complete(_ pasted: String) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        struct Done: Decodable { var userName: String }
        do {
            let d: Done = try await HarborEngine.shared.call("\(service).complete", [pasted])
            url = nil
            await refresh()
            // anilist-connect-modal.tsx / mal-connect-modal.tsx: t("Connected as {username}").
            note = T("Connected as %@", d.userName)
            noteOk = true
            return true
        } catch {
            let text = "\(error)".replacingOccurrences(of: "JS error: ", with: "")
            note = text.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "") ?? T("Sign-in failed.")
            noteOk = false
            return false
        }
    }

    func disconnect() async {
        _ = try? await HarborEngine.shared.callJSON("\(service).disconnect", [])
        url = nil
        // The last "Connected as …" stayed up under "Not connected".
        note = nil
        noteOk = false
        await refresh()
    }
}
