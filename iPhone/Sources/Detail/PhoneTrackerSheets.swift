import SwiftUI

/// The tracker sign-ins on the phone, reached from the title page's More menu: Trakt and Simkl sign
/// in with a device code (the TV's TraktPanel), AniList and MyAnimeList with a pasted code
/// (PasteTrackerPanel), all over App/Shared/Trackers. A phone holds the browser itself, so the
/// sign-in page opens right here instead of behind a QR code, and the code can be copied in one tap.
struct PhoneTrackersSheet: View {
    let close: () -> Void

    var body: some View {
        PhoneDialogPage(title: T("Trackers"), identifier: "trackers-sheet", close: close) {
            VStack(alignment: .leading, spacing: 22) {
                card("Trakt") { PhoneTraktPanel(service: "trakt", label: "Trakt") }
                card("Simkl") { PhoneTraktPanel(service: "simkl", label: "Simkl") }
                card("AniList") { PhonePastePanel(service: "anilist", label: "AniList") }
                card("MyAnimeList") { PhonePastePanel(service: "mal", label: "MyAnimeList") }
            }
        }
    }

    private func card<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: name)
                .font(PhoneTheme.sans(17, .bold, relativeTo: .headline))
                .foregroundStyle(BP.ink)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous).fill(BP.ink.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tracker-card-\(name)")
    }
}

/// The status line and note shared by both panels.
private struct TrackerNote: View {
    let text: String
    let ok: Bool

    var body: some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(14, .medium, relativeTo: .footnote))
            .foregroundStyle(ok ? BP.live : BP.danger)
    }
}

private func trackerReconnectNote(_ label: String) -> some View {
    // The TV's note, kept on this iPhone rather than this Apple TV.
    Text(verbatim: T("Your %@ sign-in has expired and can't be renewed: Harbor's sign-in server has shut down. Your connection details are kept on this iPhone.", label))
        .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
        .foregroundStyle(BP.inkMuted)
}

private func trackerHeadline(_ text: String) -> some View {
    Text(verbatim: text)
        .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
        .foregroundStyle(BP.ink)
}

private func trackerBody(_ text: String) -> some View {
    Text(verbatim: text)
        .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
        .foregroundStyle(BP.inkMuted)
}

/// TraktPanel on the phone: Connect shows the device code with Copy and a link to the page that
/// takes it, while the model polls; Cancel stops that, Disconnect asks first. Simkl adds its
/// scrobble switch once connected.
struct PhoneTraktPanel: View {
    @StateObject private var model: TraktModel
    @ObservedObject private var settings = SettingsBridge.shared
    @Environment(\.openURL) private var openURL
    @State private var confirmDisconnect = false
    @State private var copied = false
    /// When the waiting code was approved: Cancel has just become Disconnect under the finger.
    @State private var connectedAt: Date?

    init(service: String, label: String) {
        _model = StateObject(wrappedValue: TraktModel(service: service, label: label))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.status.authenticated {
                trackerHeadline(T("Connected as %@", model.status.username ?? "\(model.label) user"))
                if model.status.reconnect == true { trackerReconnectNote(model.label) }
                if model.service == "simkl" {
                    let on = settings.slice.simklScrobbleEnabled ?? true
                    Toggle(isOn: Binding(get: { on }, set: { v in Task { try? await settings.patch(["simklScrobbleEnabled": .bool(v)]) } })) {
                        Text(verbatim: T(on ? "Scrobbling on" : "Scrobbling off"))
                            .font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(BP.ink)
                    }
                    .tint(BP.accent)
                    .accessibilityIdentifier("tracker-\(model.service)-scrobble")
                }
            } else if let c = model.code {
                trackerBody(T("Open %@ and enter this code", c.verificationUrl))
                Text(verbatim: c.userCode)
                    .font(PhoneTheme.display(34, .bold, relativeTo: .largeTitle))
                    .tracking(5)
                    .foregroundStyle(BP.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("tracker-\(model.service)-code")
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = c.userCode
                        PhoneFeedback.shared.success()
                        copied = true
                    } label: {
                        Label(T(copied ? "Copied" : "Copy code"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    Button {
                        if let url = URL(string: c.verificationUrl) { openURL(url) }
                    } label: {
                        Label(T("Open sign-in page"), systemImage: "safari")
                    }
                    .buttonStyle(.glass)
                }
                HStack(spacing: 8) {
                    ProgressView()
                    trackerBody(T("Waiting for %@…", model.label))
                }
            } else if model.status.reconnect == true {
                trackerHeadline(T("Reconnect needed"))
                trackerReconnectNote(model.label)
            } else {
                trackerHeadline(T("Not connected"))
                trackerBody(T("Scrobbling, watchlist and history"))
            }
            Button(primaryTitle) { primaryAction() }
                .buttonStyle(PhonePanelButtonStyle(prominent: !model.status.authenticated && model.code == nil))
                .accessibilityIdentifier("tracker-\(model.service)-primary")
            if let n = model.note { TrackerNote(text: n, ok: model.noteOk) }
        }
        .task { await model.refresh() }
        .onChange(of: model.code?.deviceCode) { was, now in
            copied = false
            if was != nil && now == nil { connectedAt = Date() }
        }
        .onDisappear { model.cancelConnect() }
        .alert(T(model.service == "simkl" ? "Disconnect from Simkl" : "Disconnect from Trakt"), isPresented: $confirmDisconnect) {
            Button(T("Disconnect"), role: .destructive) { Task { await model.disconnect() } }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: T(model.service == "simkl" ? "Disconnect Simkl? Syncing will stop until you reconnect." : "Disconnect Trakt? Scrobbles and syncs will stop until you reconnect."))
        }
    }

    private var primaryTitle: String {
        if model.status.authenticated { return T("Disconnect") }
        if model.code != nil { return T("Cancel") }
        return T("Connect %@", model.label)
    }

    private func primaryAction() {
        if model.status.authenticated {
            // A tap meant for Cancel that lands just after the approval must not disconnect.
            if let at = connectedAt, Date().timeIntervalSince(at) < 2 { return }
            confirmDisconnect = true
        } else if model.code != nil {
            model.cancelConnect()
        } else {
            PhoneFeedback.shared.tap()
            Task { await model.connect() }
        }
    }
}

/// PasteTrackerPanel on the phone: Connect opens the service's sign-in page in the browser; the
/// code it shows comes back in the field (a rejected code stays there to fix). Disconnect asks first.
struct PhonePastePanel: View {
    @StateObject private var model: PasteTrackerModel
    @Environment(\.openURL) private var openURL
    @State private var pasted = ""
    @State private var confirmDisconnect = false

    init(service: String, label: String) {
        _model = StateObject(wrappedValue: PasteTrackerModel(service: service, label: label))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.status.authenticated {
                trackerHeadline(T("Connected as %@", model.status.username ?? "\(model.label) user"))
                trackerBody(T("Your lists show in the Anime room and the Library."))
                if model.status.reconnect == true { trackerReconnectNote(model.label) }
                Button(T("Disconnect")) { confirmDisconnect = true }
                    .buttonStyle(PhonePanelButtonStyle(prominent: false))
                    .accessibilityIdentifier("tracker-\(model.service)-primary")
            } else if let url = model.url {
                trackerBody(T("1. Open the sign-in page and sign in to %@.", model.label))
                Button {
                    if let u = URL(string: url) { openURL(u) }
                } label: {
                    Label(T("Open sign-in page"), systemImage: "safari")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("tracker-\(model.service)-open")
                trackerBody(T("2. Copy the code it shows and paste it here."))
                TextField(T("Paste the code or the whole page address"), text: $pasted)
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.ink.opacity(0.08)))
                    .accessibilityLabel(Text(verbatim: T("Code from %@", model.label)))
                    .accessibilityIdentifier("tracker-\(model.service)-field")
                HStack(spacing: 10) {
                    let empty = pasted.trimmingCharacters(in: .whitespaces).isEmpty
                    Button(T(model.busy ? "Connecting…" : "Connect")) { submit() }
                        .buttonStyle(PhonePanelButtonStyle(prominent: true))
                        .disabled(model.busy || empty)
                    Button(T("Cancel")) { Task { await model.disconnect() } }
                        .buttonStyle(PhonePanelButtonStyle(prominent: false))
                }
            } else {
                if model.status.reconnect == true {
                    trackerHeadline(T("Reconnect needed"))
                    trackerReconnectNote(model.label)
                } else {
                    trackerHeadline(T("Not connected"))
                    trackerBody(T("Your %@ lists in the Anime room and the Library", model.label))
                }
                Button(T("Connect %@", model.label)) {
                    PhoneFeedback.shared.tap()
                    Task {
                        await model.begin()
                        // One tap: the sign-in page opens as soon as its link is ready.
                        if let url = model.url, let u = URL(string: url) { openURL(u) }
                    }
                }
                .buttonStyle(PhonePanelButtonStyle(prominent: true))
                .accessibilityIdentifier("tracker-\(model.service)-primary")
            }
            if let n = model.note { TrackerNote(text: n, ok: model.noteOk) }
        }
        .task { await model.refresh() }
        .alert(T(model.service == "mal" ? "Disconnect from MyAnimeList" : "Disconnect from AniList"), isPresented: $confirmDisconnect) {
            Button(T("Disconnect"), role: .destructive) { Task { await model.disconnect() } }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: T(model.service == "mal" ? "Disconnect MyAnimeList? Your progress will stop syncing until you reconnect." : "Disconnect AniList? Your lists will stop showing on the Anime page until you reconnect."))
        }
    }

    private func submit() {
        guard !model.busy, !pasted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            if await model.complete(pasted) {
                pasted = ""
                PhoneFeedback.shared.success()
            }
        }
    }
}

/// A panel's lead button: glass, prominent for the step's next move.
private struct PhonePanelButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if prominent {
                Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.glassProminent)
            } else {
                Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.glass)
            }
        }
        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
    }
}
