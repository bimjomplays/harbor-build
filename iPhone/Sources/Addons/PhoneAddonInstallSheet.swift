import SwiftUI
import AuthenticationServices

/// install-modal.tsx + installer-viewport.tsx on the phone (AddonConfigureView on the TV). A link
/// comes in typed, pasted, scanned from a QR, or handed back by the addon's setup page: the setup
/// page opens in a web authentication session that catches the `stremio://` install link it ends
/// on, or in Safari for the pages that only show a link to copy. The link is then read as the TV
/// reads it (a new addon, an update, or a re-configure that replaces the old entry) and installed
/// with installFromUrl. Mode .url is "Add from URL", with no setup page.
struct PhoneAddonInstallSheet: View {
    let target: AddonsModel.ConfigureTarget
    @ObservedObject var model: AddonsModel
    /// Open the camera straight away ("Scan QR code" in the Add menu).
    var startScan = false
    let close: () -> Void

    struct Match: Decodable {
        var url: String?
        var name: String?
        var logo: String?
        var version: String?
        var description: String?
        var matchKind: String?
        var replaceId: String?
        var replaceName: String?
        var error: String?
    }
    private enum Phase { case idle, reading, resolved(Match), installing(Match), done(replaced: Bool, name: String, logo: String?) }

    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var pasted = ""
    @State private var phase: Phase = .idle
    /// The text the card on screen was read from: an edit after it means Read again.
    @State private var resolvedFor = ""
    @State private var error: String?
    @State private var note: String?
    @State private var prefilled = false
    @State private var scanning = false
    @State private var safari: PhoneExternalLink?
    @State private var setupOpen = false
    /// Cleared when the sheet goes: the success card's late auto-close must not close a newer one.
    private final class Shown { var on = true }
    @State private var shown = Shown()
    @FocusState private var fieldFocused: Bool

    private var setupUrl: URL? {
        guard target.mode != .url, let s = target.configureUrl, !s.isEmpty else { return nil }
        return URL(string: s)
    }
    private var busy: Bool {
        switch phase { case .reading, .installing, .done: return true; default: return false }
    }
    private var isReading: Bool { if case .reading = phase { return true }; return false }
    private var isInstalling: Bool { if case .installing = phase { return true }; return false }
    private var cardMatch: Match? {
        switch phase {
        case .resolved(let m), .installing(let m): return m
        default: return nil
        }
    }
    private var trimmed: String { pasted.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if case .done(let replaced, let name, let logo) = phase {
                        doneCard(replaced: replaced, name: name, logo: logo)
                    } else {
                        if setupUrl != nil { setupSection }
                        linkSection
                        if let m = cardMatch { resolvedCard(m) }
                    }
                }
                .padding(PhoneTheme.margin)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PhoneBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T("Done"), action: close)
                        .disabled(isInstalling)
                        .accessibilityIdentifier("install-done")
                }
            }
        }
        .interactiveDismissDisabled(isInstalling)
        .sheet(isPresented: $scanning) {
            PhoneQRScanner { payload in
                scanning = false
                take(payload)
            } close: { scanning = false }
        }
        .sheet(item: $safari, onDismiss: { note = T("Copied the install link? Paste it below.") }) { link in
            PhoneSafariView(url: link.url).ignoresSafeArea()
        }
        .onAppear {
            shown.on = true
            PhoneAddonsFixtures.installIfNeeded()
            // Once: onAppear runs again when the scanner or Safari closes over this sheet.
            guard !prefilled else { return }
            prefilled = true
            pasted = target.prefill
            if !target.prefill.isEmpty { Task { await read() } }
            // After the sheet has come up: a sheet asked for mid-presentation is dropped.
            if startScan {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    scanning = true
                }
            }
        }
        .onDisappear { shown.on = false }
        .onChange(of: pasted) { _, now in
            if case .resolved = phase, now.trimmingCharacters(in: .whitespacesAndNewlines) != resolvedFor { phase = .idle }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("install-sheet")
    }

    private var title: String {
        switch target.mode {
        case .url: return T("Add from URL")
        case .manage: return T("Manage addon")
        case .configure: return T("Setup · %@", target.name)
        }
    }

    // MARK: pieces

    /// The addon's setup page. Its URL can carry the current settings (debrid keys on a
    /// re-configure), so only the host is printed.
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let logo = target.logo { PhoneAddonLogo(url: logo, name: target.name, side: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Configure on the addon's setup page"))
                        .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                        .foregroundStyle(BP.ink)
                    Text(verbatim: setupUrl?.host ?? "")
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(BP.inkSubtle)
                }
            }
            Text(T("Pick your options there and press Install: Harbor catches the link and reads it here."))
                .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                .foregroundStyle(BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if target.mode == .manage {
                Text(T("Heads-up: a few addons (like AIOStatus) don't pre-fill from the URL. If the form loads blank, paste the existing manifest URL into their \"Import from URL\" field to restore your settings."))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { Task { await openSetup() } } label: {
                    Label(T("Open setup page"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.glassProminent)
                .disabled(busy || setupOpen)
                .accessibilityIdentifier("install-setup")
                // Pages that end on a link to copy rather than an install button.
                Button { if let setupUrl { safari = PhoneExternalLink(url: setupUrl) } } label: {
                    Label(T("Open in Safari"), systemImage: "safari")
                }
                .buttonStyle(.glass)
                .disabled(busy || setupOpen)
                .accessibilityIdentifier("install-setup-safari")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneGlassPlate()
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T(setupUrl != nil ? "Or paste the install link manually" : "Paste manifest URL or stremio:// link"))
                .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                .foregroundStyle(BP.ink)
            TextField(T("stremio://… or https://…/manifest.json"), text: $pasted, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($fieldFocused)
                .onSubmit { Task { await read() } }
                .font(PhoneTheme.sans(15, .regular, relativeTo: .body).monospaced())
                .padding(12)
                .background(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous).fill(BP.ink.opacity(0.06)))
                .disabled(busy)
                .accessibilityLabel(Text(T("Manifest URL")))
                .accessibilityIdentifier("install-url")
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in take(text) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .disabled(busy)
                .accessibilityIdentifier("install-paste")
                Button { scanning = true } label: { Label(T("Scan QR"), systemImage: "qrcode.viewfinder") }
                    .buttonStyle(.glass)
                    .disabled(busy)
                    .accessibilityIdentifier("install-scan")
                Spacer(minLength: 0)
                Button { Task { await read() } } label: {
                    if isReading { ProgressView() } else { Text(T("Read")) }
                }
                .buttonStyle(.glassProminent)
                .disabled((busy && !isReading) || trimmed.isEmpty)
                .accessibilityIdentifier("install-read")
            }
            if let note, error == nil, cardMatch == nil {
                Text(verbatim: note)
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                    .accessibilityIdentifier("install-note")
            }
            if let error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(BP.danger)
                    .accessibilityIdentifier("install-error")
            }
        }
    }

    /// install-modal.tsx: the manifest it found, the re-configure notice, Install / Update.
    private func resolvedCard(_ m: Match) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PhoneAddonLogo(url: m.logo, name: m.name ?? "", side: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: m.name ?? "")
                            .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                            .foregroundStyle(BP.ink)
                        if let v = m.version {
                            Text(verbatim: "v\(v)").font(PhoneTheme.sans(12, .regular, relativeTo: .caption)).foregroundStyle(BP.inkSubtle)
                        }
                    }
                    if let d = m.description, !d.isEmpty {
                        Text(verbatim: d)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                            .lines(3)
                    }
                }
            }
            if m.matchKind == "hostname-match", let old = m.replaceName {
                Text(T("Looks like a re-configure of %@. We'll replace the existing entry so you don't end up with two copies.", old))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                guard !isInstalling else { return }
                Task { await install(m) }
            } label: {
                HStack(spacing: 8) {
                    if isInstalling { ProgressView() }
                    Text(isInstalling ? (m.matchKind == "fresh" ? T("Installing %@", m.name ?? T("addon")) : T("Updating %@", m.name ?? T("addon")))
                                      : (m.matchKind == "fresh" ? T("Install") : T("Update")))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isInstalling)
            .accessibilityIdentifier("install-confirm")
        }
        .padding(16)
        .phoneGlassPlate()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("install-card")
    }

    private func doneCard(replaced: Bool, name: String, logo: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(BP.live)
                .accessibilityHidden(true)
            PhoneAddonLogo(url: logo, name: name, side: 52)
            Text(replaced ? T("Updated") : T("Installed"))
                .font(PhoneTheme.display(26, .semibold, relativeTo: .title2))
                .foregroundStyle(BP.ink)
            Text(verbatim: "\(name) \(replaced ? T("is now using your new configuration.") : T("is ready. Open Discover or hit Play on a title to use it."))")
                .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                .foregroundStyle(BP.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("install-finished")
    }

    // MARK: actions

    /// A pasted or scanned link: into the field, and read.
    private func take(_ text: String) {
        guard !busy else { return }
        pasted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await read() }
    }

    /// The setup page in a web authentication session. Its Install button goes to `stremio://…`,
    /// which ends the session with the link; closing it without one leaves the paste route.
    private func openSetup() async {
        guard let setupUrl, !setupOpen else { return }
        setupOpen = true
        defer { setupOpen = false }
        error = nil
        do {
            let back = try await webAuth.authenticate(using: setupUrl, callbackURLScheme: "stremio", preferredBrowserSession: .ephemeral)
            take(back.absoluteString)
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            note = T("No install link came back. Copy it on the setup page and paste it here, or open the page in Safari.")
        } catch {
            self.error = T("Couldn't open the setup page.")
        }
    }

    private func read() async {
        let raw = trimmed
        guard !raw.isEmpty, !busy else { return }
        error = nil
        guard let link = PhoneAddonLink.normalize(raw) else {
            error = T("Couldn't read that addon URL.")
            PhoneFeedback.shared.failure()
            return
        }
        phase = .reading
        let manage: AnyJSON = target.mode == .manage && target.manageId != nil
            ? .object(["id": .string(target.manageId ?? ""), "name": .string(target.name)]) : .null
        let m: Match? = try? await AddonsEngine.call("addonsManager.resolveUrl", [link, manage])
        // The link was edited while it was being read: this card is for the old one.
        guard trimmed == raw else { phase = .idle; return }
        guard let m, m.error == nil, m.url != nil else {
            phase = .idle
            error = m?.error ?? T("Couldn't read that addon URL.")
            PhoneFeedback.shared.failure()
            return
        }
        fieldFocused = false
        resolvedFor = raw
        phase = .resolved(m)
    }

    private func install(_ m: Match) async {
        guard let url = m.url else { return }
        phase = .installing(m)
        struct Result: Decodable { var ok: Bool; var replaced: Bool?; var id: String?; var name: String?; var logo: String?; var toast: String?; var message: String? }
        let r: Result? = try? await AddonsEngine.call("addonsManager.installUrl", [url, m.replaceId])
        guard let r, r.ok else {
            phase = .resolved(m)
            error = r?.message ?? T("Install failed.")
            PhoneFeedback.shared.failure()
            return
        }
        let name = r.name ?? m.name ?? T("Addon")
        phase = .done(replaced: r.replaced ?? false, name: name, logo: r.logo ?? m.logo)
        await model.installedFromLink(id: r.id ?? "", name: name, logo: r.logo, toast: r.toast ?? T("Installed"))
        // installer-viewport.tsx: the success card closes itself after two seconds.
        let sheet = shown
        try? await Task.sleep(for: .seconds(2))
        guard sheet.on else { return }
        close()
    }
}

/// A `stremio://…/manifest.json` link opened from another app: the install sheet over the shell,
/// with the link read straight away.
struct PhoneDeepLinkInstall: View {
    let url: String
    let close: () -> Void
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: AddonsModel

    init(url: String, close: @escaping () -> Void) {
        self.url = url
        self.close = close
        PhoneAddonsFixtures.installIfNeeded()
        _model = StateObject(wrappedValue: AddonsModel())
    }

    var body: some View {
        PhoneAddonInstallSheet(target: AddonsModel.ConfigureTarget(mode: .url, name: T("Addon"), logo: nil, configureUrl: nil,
                                                                  manageId: nil, prefill: url),
                               model: model, close: close)
            .phoneAddonToasts(model)
            .presentedCover("install")
            .onAppear { app.deepLinkCoverAppeared() }
    }
}
