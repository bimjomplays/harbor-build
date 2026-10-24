import SwiftUI
import CoreImage.CIFilterBuiltins


struct PasteTrackerPanel: View {
    @StateObject private var model: PasteTrackerModel
    @State private var pasted = ""
    /// anilist-panel.tsx / mal-panel.tsx: Disconnect asks first.
    @State private var confirmDisconnect = false
    /// Each step swaps the button under the ring (Connect → the code's Connect →
    /// Disconnect → Connect): the ring fell off the panel. It follows to the step's lead button.
    @FocusState private var lead: Bool
    init(service: String, label: String) { _model = StateObject(wrappedValue: PasteTrackerModel(service: service, label: label)) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if model.status.authenticated {
                Text("Connected as \(model.status.username ?? "\(model.label) user")").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your lists show in the Anime room and the Library.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                if model.status.reconnect == true { reconnectNote }
                Button("Disconnect") { confirmDisconnect = true }.buttonStyle(BPActionStyle())
                    .focused($lead)
            } else if let url = model.url {
                HStack(alignment: .top, spacing: BP.px(18)) {
                    if let qr = Self.qr(url) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(150), height: BP.px(150)).accessibilityLabel(Text(T("QR code")))
                            .padding(BP.px(8)).background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(.white))
                    }
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        Text("1. Scan the code (or open the link) on your phone and sign in to \(model.label).").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                        Text(url).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(3)
                        Text("2. Copy the code it shows and paste it here (the iPhone keyboard for Apple TV can paste).").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                        BPField(label: T("Code from %@", model.label), placeholder: "Paste the code or the whole page address", text: $pasted, phone: true)
                        HStack(spacing: BP.px(8)) {
                            // Dimmed, not disabled, while the field is empty, so
                            // the ring can wait here for the pasted code.
                            let empty = pasted.trimmingCharacters(in: .whitespaces).isEmpty
                            Button(model.busy ? "Connecting…" : "Connect") {
                                guard !model.busy, !empty else { return }
                                // A rejected code stays in the field to fix
                                // or retry; clearing it also disabled the focused Connect button.
                                Task {
                                    if await model.complete(pasted) {
                                        pasted = ""
                                        refocus()
                                    }
                                }
                            }
                                .buttonStyle(BPActionStyle(primary: true, busy: model.busy || empty))
                                .focused($lead)
                            Button("Cancel") { Task { await model.disconnect(); refocus() } }.buttonStyle(BPActionStyle())
                        }
                    }
                }
            } else {
                if model.status.reconnect == true {
                    Text("Reconnect needed").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                    reconnectNote
                } else {
                    Text("Not connected").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                    Text("Your \(model.label) lists in the Anime room and the Library").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                }
                Button("Connect \(model.label)") { Task { await model.begin(); refocus() } }.buttonStyle(BPActionStyle(primary: true))
                    .focused($lead)
            }
            if let n = model.note { BPNote(text: n, tone: model.noteOk ? BP.live : BP.danger) }
        }
        .task { await model.refresh() }
        .alert(disconnectTitle, isPresented: $confirmDisconnect) {
            // After the alert has gone, as review 24 did for the Live Sources
            // Remove: the engine's disconnect answers before the alert finishes dismissing, and a
            // focus set under a presented alert is dropped, so the ring fell off the panel.
            Button(T("Disconnect"), role: .destructive) { Task { await model.disconnect(); refocus(after: 0.4) } }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: disconnectMessage)
        }
    }

    /// The step's lead button, once it is on screen.
    private func refocus(after delay: Double = 0.1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { lead = true }
    }

    /// The sign-in expired and Harbor's token server, which renewed it, has shut down.
    private var reconnectNote: some View {
        Text("Your \(model.label) sign-in has expired and can't be renewed: Harbor's sign-in server has shut down. Your connection details are kept on this Apple TV.")
            .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
    }

    private var disconnectTitle: String {
        T(model.service == "mal" ? "Disconnect from MyAnimeList" : "Disconnect from AniList")
    }

    private var disconnectMessage: String {
        T(model.service == "mal" ? "Disconnect MyAnimeList? Your progress will stop syncing until you reconnect." : "Disconnect AniList? Your lists will stop showing on the Anime page until you reconnect.")
    }

    private static func qr(_ text: String) -> UIImage? { QRCode.image(text) }
}
