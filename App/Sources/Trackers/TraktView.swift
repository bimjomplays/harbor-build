import SwiftUI


struct TraktPanel: View {
    @StateObject private var model: TraktModel
    @ObservedObject private var settings = SettingsBridge.shared
    /// When the waiting code was approved: the Cancel under the ring has just become Disconnect.
    @State private var connectedAt: Date?
    /// trakt-panel.tsx / simkl-panel.tsx: Disconnect asks first (SettingsModal
    /// "Disconnect from Trakt"); one press signed the tracker out at once.
    @State private var confirmDisconnect = false
    init(service: String = "trakt", label: String = "Trakt") {
        _model = StateObject(wrappedValue: TraktModel(service: service, label: label))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if model.status.authenticated {
                Text("Connected as \(model.status.username ?? "\(model.label) user")").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Scrobbles what you watch; watchlist and history sync arrive in a later release.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                if model.status.reconnect == true { reconnectNote }
            } else if let c = model.code {
                Text("On your phone, open \(c.verificationUrl) and enter").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Text(c.userCode).font(BP.display(44)).foregroundStyle(BP.ink).tracking(6)
                HStack(spacing: BP.px(8)) { ProgressView().tint(BP.inkMuted); Text("Waiting for \(model.label)…").font(BP.sans(13)).foregroundStyle(BP.inkSubtle) }
            } else if model.status.reconnect == true {
                Text("Reconnect needed").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                reconnectNote
            } else {
                Text("Not connected").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Scrobbling, watchlist and history").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
            // One button that changes with the state (Connect → Cancel →
            // Disconnect) rather than three: Connect vanished once the code showed, leaving the
            // waiting panel with nothing to focus or cancel (trakt-device-modal.tsx has Cancel), and
            // the ring jumped elsewhere on the page; the same happened when the code was approved.
            HStack(spacing: BP.px(8)) {
                Button(primaryTitle) { primaryAction() }.buttonStyle(BPActionStyle(primary: !model.status.authenticated && model.code == nil))
                if model.status.authenticated && model.service == "simkl" {
                    let on = settings.slice.simklScrobbleEnabled ?? true
                    Button(on ? "Scrobbling on" : "Scrobbling off") { Task { try? await settings.patch(["simklScrobbleEnabled": .bool(!on)]) } }.buttonStyle(BPActionStyle(primary: on))
                }
            }
            if let n = model.note { BPNote(text: n, tone: model.noteOk ? BP.live : BP.danger) }
        }
        .task { await model.refresh() }
        .onChange(of: model.code?.deviceCode) { was, now in
            if was != nil && now == nil { connectedAt = Date() }
        }
        .onDisappear { model.cancelConnect() }   //
        .alert(disconnectTitle, isPresented: $confirmDisconnect) {
            Button(T("Disconnect"), role: .destructive) { Task { await model.disconnect() } }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: disconnectMessage)
        }
    }

    /// The sign-in expired and Harbor's token server, which renewed it, has shut down.
    private var reconnectNote: some View {
        Text("Your \(model.label) sign-in has expired and can't be renewed: Harbor's sign-in server has shut down. Your connection details are kept on this Apple TV.")
            .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
    }

    private var disconnectTitle: String {
        T(model.service == "simkl" ? "Disconnect from Simkl" : "Disconnect from Trakt")
    }

    private var disconnectMessage: String {
        T(model.service == "simkl" ? "Disconnect Simkl? Syncing will stop until you reconnect." : "Disconnect Trakt? Scrobbles and syncs will stop until you reconnect.")
    }

    // T(): a String title is not looked up the way a Button literal is.
    private var primaryTitle: String {
        if model.status.authenticated { return T("Disconnect") }
        if model.code != nil { return T("Cancel") }
        return T("Connect %@", model.label)
    }

    private func primaryAction() {
        if model.status.authenticated {
            // A press meant for Cancel that lands just after the approval must not disconnect.
            if let at = connectedAt, Date().timeIntervalSince(at) < 2 { return }
            confirmDisconnect = true
        } else if model.code != nil {
            model.cancelConnect()
        } else {
            Task { await model.connect() }
        }
    }
}
