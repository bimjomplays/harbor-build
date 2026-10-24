import SwiftUI
import Combine

/// The phone's door to HomeServersModel. Live, every call is the model's own (engine homeServers.*);
/// on `--fixtures` (nothing to reach, nothing to save) the connections live in memory so the add,
/// test and remove flows can be walked through offline.
@MainActor
final class PhoneHomeServersModel: ObservableObject {
    private let live = HomeServersModel()
    private let fixtures = PhoneSettingsFixtures.active
    private var forward: AnyCancellable?
    @Published private var local: [HomeServersModel.Connection] = []
    @Published private var localPin: HomeServersModel.Pin?
    @Published private var localNote: String?
    @Published private var localNoteOk = false
    @Published private var localBusy = false
    private var serial = 0

    init() {
        forward = live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var connections: [HomeServersModel.Connection] { fixtures ? local : live.connections }
    var pin: HomeServersModel.Pin? { fixtures ? localPin : live.pin }
    var servers: [HomeServersModel.Poll.Server] { fixtures ? [] : live.servers }
    var progress: [String: String] { fixtures ? [:] : live.progress }
    var note: String? { fixtures ? localNote : live.note }
    var noteOk: Bool { fixtures ? localNoteOk : live.noteOk }
    var busy: Bool { fixtures ? localBusy : live.busy }

    func load() async {
        if !fixtures { await live.load() }
    }

    func startPlex() async {
        if fixtures {
            localNote = nil
            localPin = HomeServersModel.Pin(pinId: 1, code: "FX42", url: "https://plex.tv/link", expiresAt: Date().timeIntervalSince1970 * 1000 + 900_000)
        } else {
            await live.startPlex()
        }
    }

    func cancelPlex() {
        if fixtures { localPin = nil } else { live.cancelPlex() }
    }

    func addPlex(_ server: HomeServersModel.Poll.Server) async {
        if !fixtures { await live.addPlex(server) }
    }

    func connect(provider: String, address: String, username: String, password: String) async -> Bool {
        guard fixtures else { return await live.connect(provider: provider, address: address, username: username, password: password) }
        guard !address.isEmpty else { return false }
        serial += 1
        let name = provider == "emby" ? "Fixture Emby" : "Fixture Jellyfin"
        local.append(HomeServersModel.Connection(id: "fx-\(serial)", provider: provider, name: name, origin: address, enabled: true))
        await sync("fx-\(serial)")
        return true
    }

    func sync(_ id: String) async {
        guard fixtures else { await live.sync(id); return }
        guard let at = local.firstIndex(where: { $0.id == id }) else { return }
        let now = Date().timeIntervalSince1970 * 1000
        local[at].lastSyncAt = now
        local[at].lastSummary = .init(at: now, movies: 120, shows: 14, episodes: 380)
        local[at].lastSyncResult = .init(ok: true, message: "Indexed 514 items from 2 libraries.", at: now)
        localNote = T("Indexed %lld items from %lld libraries.", 514, 2)
        localNoteOk = true
    }

    func remove(_ id: String) async {
        if fixtures { local.removeAll { $0.id == id } } else { await live.remove(id) }
    }

    func toggle(_ c: HomeServersModel.Connection) async {
        if fixtures {
            if let at = local.firstIndex(where: { $0.id == c.id }) { local[at].enabled.toggle() }
        } else {
            await live.toggle(c)
        }
    }

    /// home-servers-tab.tsx pickers: `field` is "preferredQuality" or "refreshInterval".
    func set(_ c: HomeServersModel.Connection, field: String, to value: String) async {
        if fixtures {
            guard let at = local.firstIndex(where: { $0.id == c.id }) else { return }
            if field == "preferredQuality" { local[at].preferredQuality = value } else { local[at].refreshInterval = value }
            return
        }
        _ = try? await HarborEngine.shared.callJSON("homeServers.update", [.string(c.id), .object([field: .string(value)])])
        await live.load()
    }
}

/// Settings → Home servers, the TV's HomeServersPanel on a Form: each connection (summary, enabled,
/// quality, refresh, test, remove), then Plex through the plex.tv/link code and Jellyfin / Emby by
/// address and sign-in. Passwords go to the engine and are not kept here.
struct PhoneHomeServersPanel: View {
    @StateObject private var model = PhoneHomeServersModel()
    @State private var provider = "jellyfin"
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var removing: HomeServersModel.Connection?
    private enum Field { case address, username, password }
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            if model.connections.isEmpty {
                Section {
                    Text(verbatim: T("No home servers yet. Add Plex, Jellyfin or Emby and its movies and shows join your library."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("servers-empty")
                }
            }
            ForEach(model.connections) { c in connection(c) }
            plexSection
            addSection
            if let note = model.note {
                Section { PhoneSettingsNote(text: note, ok: model.noteOk).accessibilityIdentifier("servers-note") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Home servers"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(removing.map { T("Remove %@?", $0.name) } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { c in
            Button(T("Remove"), role: .destructive) { Task { await model.remove(c.id) } }
                .accessibilityIdentifier("server-remove-confirm")
            Button(T("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(verbatim: T("Its movies and shows leave your library. The server itself is not touched."))
        }
        .task { await model.load() }
        .onDisappear { model.cancelPlex() }
        .accessibilityIdentifier("settings-servers")
    }

    // MARK: a connection

    private func connection(_ c: HomeServersModel.Connection) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: c.name).font(PhoneTheme.sans(17, .semibold, relativeTo: .body)).foregroundStyle(BP.ink)
                Text(verbatim: "\(c.provider.capitalized) · \(c.origin)")
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote)).foregroundStyle(.secondary)
                    .lines(2)
                if let line = model.progress[c.id] ?? lastLine(c) {
                    Text(verbatim: line).font(PhoneTheme.sans(13, .regular, relativeTo: .footnote)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("server-row-\(c.id)")
            Toggle(T("Enabled"), isOn: Binding(get: { c.enabled }, set: { _ in Task { await model.toggle(c) } }))
                .accessibilityIdentifier("server-enabled-\(c.id)")
            Picker(T("Quality"), selection: Binding(get: { c.preferredQuality ?? "original" }, set: { v in Task { await model.set(c, field: "preferredQuality", to: v) } })) {
                ForEach(HomeServersModel.qualities, id: \.0) { Text(verbatim: T($0.1)).tag($0.0) }
            }
            .accessibilityIdentifier("server-quality-\(c.id)")
            Picker(T("Refresh"), selection: Binding(get: { c.refreshInterval ?? "launch" }, set: { v in Task { await model.set(c, field: "refreshInterval", to: v) } })) {
                ForEach(HomeServersModel.intervals, id: \.0) { Text(verbatim: T($0.1)).tag($0.0) }
            }
            .accessibilityIdentifier("server-refresh-\(c.id)")
            Button(model.progress[c.id] != nil ? T("Testing…") : T("Test connection")) { Task { await model.sync(c.id) } }
                .disabled(model.progress[c.id] != nil)
                .accessibilityIdentifier("server-test-\(c.id)")
            Button(T("Remove"), role: .destructive) { removing = c }
                .accessibilityIdentifier("server-remove-\(c.id)")
        }
    }

    private func lastLine(_ c: HomeServersModel.Connection) -> String? {
        if let s = c.lastSummary { return T("%lld movies · %lld shows · %lld episodes", s.movies, s.shows, s.episodes) }
        return c.lastSyncResult?.message
    }

    // MARK: Plex

    private var plexSection: some View {
        Section {
            if let pin = model.pin {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: T("Enter this code at plex.tv/link"))
                        .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote)).foregroundStyle(.secondary)
                    Text(verbatim: pin.code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(BP.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("plex-code")
                }
                if let link = URL(string: "https://plex.tv/link") {
                    Link(T("Open plex.tv/link"), destination: link).accessibilityIdentifier("plex-link")
                }
                if model.servers.isEmpty {
                    Text(verbatim: T("Waiting for you to approve it…")).foregroundStyle(.secondary)
                }
                ForEach(model.servers) { s in
                    Button {
                        Task { await model.addPlex(s) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: s.name)
                            Text(verbatim: s.available ? s.origin : T("Not reachable right now"))
                                .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote)).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("plex-server-\(s.id)")
                }
                Button(T("Cancel"), role: .cancel) { model.cancelPlex() }.accessibilityIdentifier("plex-cancel")
            } else {
                Button(T("Add a Plex server")) { Task { await model.startPlex() } }
                    .accessibilityIdentifier("plex-add")
            }
        } header: {
            Text(verbatim: "Plex")
        } footer: {
            Text(verbatim: T("Approve a code at plex.tv/link, then choose which of your servers to add."))
        }
    }

    // MARK: Jellyfin and Emby

    private var addSection: some View {
        Section {
            Picker(T("Server type"), selection: $provider) {
                Text(verbatim: "Jellyfin").tag("jellyfin")
                Text(verbatim: "Emby").tag("emby")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("server-provider")
            TextField(T("Server address"), text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .username }
                .accessibilityIdentifier("server-address")
            TextField(T("Username"), text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .accessibilityIdentifier("server-username")
            SecureField(T("Password"), text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.done)
                .onSubmit { focus = nil }
                .accessibilityIdentifier("server-password")
            Button(model.busy ? T("Connecting…") : T("Test and add")) {
                Task {
                    let ok = await model.connect(provider: provider, address: address.trimmingCharacters(in: .whitespaces), username: username.trimmingCharacters(in: .whitespaces), password: password)
                    if ok {
                        address = ""; username = ""; password = ""
                        PhoneFeedback.shared.success()
                    } else {
                        PhoneFeedback.shared.failure()
                    }
                }
            }
            .disabled(model.busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("server-connect")
        } header: {
            Text(verbatim: "Jellyfin · Emby")
        } footer: {
            Text(verbatim: T("Use the address you open in a browser, such as http://192.168.1.20:8096. The password is sent to the server and not kept."))
        }
    }
}
