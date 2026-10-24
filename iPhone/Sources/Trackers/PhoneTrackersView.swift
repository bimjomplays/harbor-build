import SwiftUI
import UIKit

/// Account → Trackers: every tracker the TV's Settings signs in to, with its sign-in state. A row
/// opens the tracker's page (sign in, sign out, Sync now, its options). A title's own tracker
/// status stays on its page's More menu.
struct PhoneTrackersView: View {
    @StateObject private var model = PhoneTrackersModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    ForEach(Array(PhoneTracker.allCases.enumerated()), id: \.element) { index, tracker in
                        if index > 0 { Divider().padding(.leading, 56) }
                        row(tracker)
                    }
                }
                .phoneGlassPlate()
                Text(T("To mark a title watched or add it to a list on a tracker, open the title and use More."))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.vertical, 12)
        }
        .background(PhoneBackground())
        .navigationTitle(T("Trackers"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("trackers-screen")
    }

    private func row(_ tracker: PhoneTracker) -> some View {
        let state = model.state(tracker)
        return NavigationLink {
            PhoneTrackerPage(tracker: tracker, model: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: tracker.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BP.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tracker.label)
                        .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                        .foregroundStyle(BP.ink)
                    Text(verbatim: model.loaded ? state.title(for: tracker) : T("Checking…"))
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(PhoneTrackerPage.tint(state))
                        .accessibilityIdentifier("tracker-status-\(tracker.id)")
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(BP.inkSubtle)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tracker.label))
        .accessibilityValue(Text(verbatim: model.loaded ? state.title(for: tracker) : T("Checking…")))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tracker-\(tracker.id)")
    }
}

/// One tracker: its sign-in (in place, in a web auth sheet, where the TV shows a QR code), its
/// lists and Sync now, and the switches the TV's panel has for it.
struct PhoneTrackerPage: View {
    let tracker: PhoneTracker
    @ObservedObject var model: PhoneTrackersModel

    @StateObject private var device: TraktModel
    @StateObject private var paste: PasteTrackerModel
    @StateObject private var letterboxd = LetterboxdModel()
    @StateObject private var simkl = PhoneSimklOptions()
    @StateObject private var web = PhoneWebAuth()
    @ObservedObject private var layouts = HomeLayoutStore.shared

    @State private var pastedCode = ""
    @State private var showPaste = false
    @State private var username = ""
    @State private var localNote: String?
    @State private var localNoteOk = false
    @State private var confirmSignOut = false
    @State private var working = false

    init(tracker: PhoneTracker, model: PhoneTrackersModel) {
        self.tracker = tracker
        self.model = model
        _device = StateObject(wrappedValue: TraktModel(service: tracker.service, label: tracker.label))
        _paste = StateObject(wrappedValue: PasteTrackerModel(service: tracker.service, label: tracker.label))
    }

    private var state: PhoneTrackerState { model.state(tracker) }

    private var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                signInSection
                if state.hasSession {
                    syncSection
                    optionsSection
                    signOutButton
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.vertical, 12)
        }
        .background(PhoneBackground())
        .navigationTitle(tracker.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refresh(tracker)
            if state.hasSession { await model.loadLists(tracker) }
            if tracker == .simkl { await simkl.load() }
        }
        .onChange(of: device.code?.deviceCode) { old, now in
            // The poll's verdict came in (or the code ran out) while the web sheet was up. The state
            // is read from the engine whatever the verdict: signedIn syncs only if there's a session.
            guard PhoneTrackerAuth.deviceCodeEnded(from: old, to: now) else { return }
            web.close()
            Task { await model.signedIn(tracker) }
        }
        .onDisappear {
            device.cancelConnect()
            web.close()
        }
        .confirmationDialog(T(PhoneTrackerPage.disconnectTitle(tracker)), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(T("Disconnect"), role: .destructive) {
                Task {
                    working = true
                    // Through this page's own models, so their "Connected as …" lines go too.
                    await model.signOut(tracker, disconnect: disconnect)
                    working = false
                    say(nil)
                    showPaste = false
                    pastedCode = ""
                    PhoneFeedback.shared.success()
                }
            }
            .accessibilityIdentifier("tracker-signout-confirm")
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: T(PhoneTrackerPage.disconnectMessage(tracker)))
        }
        .accessibilityIdentifier("tracker-page-\(tracker.id)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: tracker.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(BP.accent)
                .frame(width: 52, height: 52)
                .phoneGlassPlate(radius: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: tracker.label)
                    .font(PhoneTheme.display(26, .semibold, relativeTo: .title))
                    .foregroundStyle(BP.ink)
                Text(verbatim: state.title(for: tracker))
                    .font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Self.tint(state))
                    .accessibilityIdentifier("tracker-page-status")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    // MARK: Sign in

    @ViewBuilder
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .connected:
                EmptyView()
            case .reconnect:
                Text(T("Your %@ sign-in has expired and can't be renewed: Harbor's sign-in server has shut down.", tracker.label))
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                    .foregroundStyle(BP.inkMuted)
                connectButton(T("Reconnect"))
            case .signedOut:
                Text(verbatim: tracker.blurb)
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                    .foregroundStyle(BP.inkMuted)
                if tracker.flow == .username {
                    TextField(T("Letterboxd username"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                        .padding(12)
                        .phoneGlassPlate(radius: 12)
                        .accessibilityIdentifier("tracker-username")
                }
                connectButton(T("Connect"))
            }
            if let code = device.code, tracker.flow == .deviceCode {
                deviceCodeCard(code)
            }
            if showPaste, tracker.flow == .authorizeCode, !isConnected {
                pasteCard
            }
            if let note {
                Text(verbatim: note.text)
                    .font(PhoneTheme.sans(14, .medium, relativeTo: .footnote))
                    .foregroundStyle(note.ok ? BP.live : BP.danger)
                    .accessibilityIdentifier("tracker-note")
            }
        }
    }

    /// The latest line from whichever sign-in ran (the shared models' own notes, as on the TV).
    private var note: (text: String, ok: Bool)? {
        if let localNote { return (localNote, localNoteOk) }
        switch tracker.flow {
        case .deviceCode: return device.note.map { ($0, device.noteOk) }
        case .authorizeCode: return paste.note.map { ($0, paste.noteOk) }
        case .username: return letterboxd.note.map { ($0, letterboxd.noteOk) }
        }
    }

    private var busy: Bool { working || paste.busy || letterboxd.busy || web.isOpen }

    private func connectButton(_ title: String) -> some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(verbatim: title).font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .disabled(busy || (tracker.flow == .username && username.trimmingCharacters(in: .whitespaces).isEmpty))
        .accessibilityIdentifier("tracker-connect")
    }

    private func deviceCodeCard(_ code: TraktModel.Code) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(T("Approve Harbor on %@ with this code:", tracker.label))
                .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                .foregroundStyle(BP.inkMuted)
            Text(verbatim: code.userCode)
                .font(.system(.title, design: .monospaced).weight(.bold))
                .foregroundStyle(BP.ink)
                .textSelection(.enabled)
                .accessibilityIdentifier("tracker-device-code")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(T("Waiting for %@…", tracker.label))
                    .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                Spacer(minLength: 0)
                Button(T("Open page")) { openApproval(code) }
                    .buttonStyle(.glass)
                    .disabled(web.isOpen)
            }
        }
        .padding(16)
        .phoneGlassPlate()
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(T("Copy the code %@ shows after you approve, then paste it here.", tracker.label))
                .font(PhoneTheme.sans(15, .regular, relativeTo: .callout))
                .foregroundStyle(BP.inkMuted)
            HStack(spacing: 8) {
                TextField(T("Code or page address"), text: $pastedCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .phoneGlassPlate(radius: 12)
                    .accessibilityIdentifier("tracker-paste-field")
                // PasteButton reads the pasteboard without the "Allow Paste" prompt.
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { @MainActor in pastedCode = first }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
            }
            HStack(spacing: 10) {
                Button(T("Open page")) { Task { await openAuthorize() } }
                    .buttonStyle(.glass)
                    .disabled(busy)
                Spacer(minLength: 0)
                Button(T("Finish sign-in")) { Task { await finishPaste(pastedCode) } }
                    .buttonStyle(.glassProminent)
                    .disabled(busy || PhoneTrackerAuth.code(fromPasted: pastedCode) == nil)
                    .accessibilityIdentifier("tracker-paste-finish")
            }
        }
        .padding(16)
        .phoneGlassPlate()
    }

    private func say(_ text: String?, ok: Bool = false) {
        localNote = text
        localNoteOk = ok
    }

    private func connect() {
        say(nil)
        PhoneFeedback.shared.tap()
        guard !model.fixtures else {
            say(T("Signing in isn't available in the demo."))
            return
        }
        Task {
            switch tracker.flow {
            case .deviceCode:
                await device.connect()
                if let code = device.code { openApproval(code) }
            case .authorizeCode:
                await paste.begin()
                if paste.url != nil {
                    showPaste = true
                    await openAuthorize()
                }
            case .username:
                await letterboxd.connect(username.trimmingCharacters(in: .whitespaces))
                if letterboxd.status?.active == true {
                    username = ""
                    PhoneFeedback.shared.success()
                    await model.signedIn(tracker)
                }
            }
        }
    }

    /// The device code's approval page in the web auth sheet; the poll (TraktModel) learns the
    /// answer, and closes the sheet through `onChange(of: device.code)`. Trakt's page asks for the
    /// code, so it goes on the clipboard first.
    private func openApproval(_ code: TraktModel.Code) {
        guard let url = PhoneTrackerAuth.approvalURL(for: tracker, userCode: code.userCode, verificationUrl: code.verificationUrl) else { return }
        if tracker != .simkl { UIPasteboard.general.string = code.userCode }
        Task { _ = try? await web.open(url) }
    }

    /// AniList / MyAnimeList's authorize page. A redirect back to Harbor finishes at once; the
    /// services' own code pages leave the code to be pasted.
    private func openAuthorize() async {
        guard let url = PhoneTrackerAuth.webURL(paste.url) else {
            if paste.url == nil { await paste.begin() }
            return
        }
        do {
            guard let callback = try await web.open(url) else { return }
            switch PhoneTrackerAuth.parseCallback(callback) {
            case .code(let code): await finishPaste(code)
            case .denied(let detail): say(detail ?? T("%@ said no.", tracker.label))
            case .invalid: say(T("Sign-in failed."))
            }
        } catch {
            say(PhoneTrackerAuth.engineMessage(error) ?? T("Sign-in failed."))
        }
    }

    private func finishPaste(_ text: String) async {
        guard let code = PhoneTrackerAuth.code(fromPasted: text) else { return }
        say(nil)
        if await paste.complete(code) {
            pastedCode = ""
            showPaste = false
            PhoneFeedback.shared.success()
            await model.signedIn(tracker)
        } else {
            PhoneFeedback.shared.failure()
        }
    }

    private func disconnect() async {
        guard !model.fixtures else { return }
        switch tracker.flow {
        case .deviceCode: await device.disconnect()
        case .authorizeCode: await paste.disconnect()
        case .username: await letterboxd.disable()
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: T("Lists"))
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let _ = model.syncRevision
                        Text(verbatim: PhoneTrackerSyncLog.text(model.lastSynced(tracker), now: context.date))
                            .font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(BP.inkMuted)
                            .accessibilityIdentifier("tracker-synced")
                    }
                    Spacer(minLength: 0)
                    Button {
                        PhoneFeedback.shared.tap()
                        Task {
                            if await model.sync(tracker) { PhoneFeedback.shared.success() } else { PhoneFeedback.shared.warning() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if model.syncing.contains(tracker) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                            }
                            Text(T("Sync now"))
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(model.syncing.contains(tracker))
                    .accessibilityIdentifier("tracker-sync")
                }
                if model.syncFailed.contains(tracker) {
                    Text(T("Couldn't reach %@. Try again in a moment.", tracker.label))
                        .font(PhoneTheme.sans(14, .medium, relativeTo: .footnote))
                        .foregroundStyle(BP.danger)
                        .accessibilityIdentifier("tracker-sync-failed")
                }
                if let lists = model.lists[tracker] {
                    Divider()
                    ForEach(lists.groups) { group in
                        HStack {
                            Text(verbatim: T(group.label)).foregroundStyle(BP.ink)
                            Spacer()
                            Text(verbatim: "\(group.count)").monospacedDigit().foregroundStyle(BP.inkMuted)
                        }
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .body))
                        .accessibilityElement(children: .combine)
                    }
                    HStack {
                        Text(T("All")).foregroundStyle(BP.ink)
                        Spacer()
                        Text(verbatim: "\(lists.total)").monospacedDigit().foregroundStyle(BP.ink)
                    }
                    .font(PhoneTheme.sans(15, .semibold, relativeTo: .body))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tracker-list-total")
                }
            }
            .padding(16)
            .phoneGlassPlate()
        }
    }

    // MARK: Options

    @ViewBuilder
    private var optionsSection: some View {
        switch tracker {
        case .simkl:
            options {
                toggle(T("Scrobbling"), detail: T("Mark what you watch on Simkl as you watch it."), id: "simkl-scrobble",
                       isOn: simkl.scrobble) { on in Task { await simkl.setScrobble(on) } }
                Divider()
                toggle(T("Simkl rows on Home"), detail: nil, id: "simkl-home", isOn: simkl.home) { on in Task { await simkl.setRail("home", on) } }
                toggle(T("Up Next"), detail: nil, id: "simkl-upnext", isOn: simkl.upNext) { on in Task { await simkl.setRail("upNext", on) } }
                    .disabled(!simkl.home)
                toggle(T("Trending"), detail: nil, id: "simkl-trending", isOn: simkl.trending) { on in Task { await simkl.setRail("trending", on) } }
                    .disabled(!simkl.home)
            }
        case .anilist, .mal:
            options {
                Text(T("Show on Home"))
                    .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                ForEach(tracker.homeRails, id: \.key) { rail in
                    if let source = tracker.homeSource(railKey: rail.key) {
                        toggle(T(rail.title), detail: nil, id: "\(tracker.id)-home-\(rail.key)", isOn: onHome(source)) { on in
                            setOnHome(source, title: rail.title, on)
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func options<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: T("Options"))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(16)
                .phoneGlassPlate()
        }
    }

    private func toggle(_ title: String, detail: String?, id: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { PhoneFeedback.shared.selection(); set($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(PhoneTheme.sans(16, .medium, relativeTo: .body)).foregroundStyle(BP.ink)
                if let detail {
                    Text(verbatim: detail).font(PhoneTheme.sans(13, .regular, relativeTo: .footnote)).foregroundStyle(BP.inkMuted)
                }
            }
        }
        .tint(BP.accent)
        .accessibilityIdentifier(id)
    }

    private var profileId: String { ProfilesStore.shared.active?.id ?? "default" }

    private func onHome(_ source: HomeRowSource) -> Bool {
        _ = layouts.revision
        return layouts.layout(for: profileId).contains(source)
    }

    /// The same row the Home editor adds ("AniList · Watching"), or every copy of it taken off.
    private func setOnHome(_ source: HomeRowSource, title: String, _ on: Bool) {
        layouts.update(for: profileId) { layout in
            if on {
                if !layout.contains(source) { layout.insert(source, savedTitle: "\(tracker.label) · \(T(title))") }
            } else {
                layout.rows.removeAll { $0.source.identity == source.identity }
            }
        }
    }

    // MARK: Sign out

    private var signOutButton: some View {
        Button(role: .destructive) {
            confirmSignOut = true
        } label: {
            Text(T("Disconnect"))
                .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                .foregroundStyle(BP.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .disabled(working)
        .accessibilityIdentifier("tracker-signout")
    }

    static func tint(_ state: PhoneTrackerState) -> Color {
        switch state {
        case .connected: return BP.live
        case .reconnect: return BP.danger
        case .signedOut: return BP.inkMuted
        }
    }

    /// The TV panels' Disconnect confirmations (TraktView, PasteTrackerView, LetterboxdPanel).
    static func disconnectTitle(_ tracker: PhoneTracker) -> String {
        switch tracker {
        case .trakt: return "Disconnect from Trakt"
        case .simkl: return "Disconnect from Simkl"
        case .anilist: return "Disconnect from AniList"
        case .mal: return "Disconnect from MyAnimeList"
        case .letterboxd: return "Turn off Letterboxd"
        }
    }

    static func disconnectMessage(_ tracker: PhoneTracker) -> String {
        switch tracker {
        case .trakt: return "Disconnect Trakt? Scrobbles and syncs will stop until you reconnect."
        case .simkl: return "Disconnect Simkl? Syncing will stop until you reconnect."
        case .anilist: return "Disconnect AniList? Your lists will stop showing on the Anime page until you reconnect."
        case .mal: return "Disconnect MyAnimeList? Your progress will stop syncing until you reconnect."
        case .letterboxd: return "Your Letterboxd watchlist and rows will stop showing until you connect again."
        }
    }
}
