import SwiftUI

/// Settings → Home rows. The phone's Home is arranged in Edit Home (PhoneHomeEditor), so the first
/// row opens it, on its own loader: HomeLayoutStore keeps the layout, so Home follows every change.
/// Below it, what the TV's HomeRowsPanel sets in the engine and the phone's Home also draws: lists
/// on Home, the Simkl rails and Continue Watching (rooms.homeRowsState and its editors).
struct PhoneHomeRowsPanel: View {
    /// engine/homeExtras.ts HomeRowsState (the TV's HomeRowsPanel reads the same; its row editing is
    /// Edit Home's on the phone).
    struct RowsState: Decodable {
        struct ListEntry: Decodable, Identifiable { var id: String; var name: String; var count: Int; var onHome: Bool }
        struct Simkl: Decodable { var connected: Bool; var home: Bool; var upNext: Bool; var trending: Bool }
        struct Cw: Decodable { var advanceNext: Bool; var hideCaughtUp: Bool; var animeCwEnd: String }
        var lists: [ListEntry]
        var simkl: Simkl
        var cw: Cw?
    }

    @EnvironmentObject private var app: AppModel
    @State private var state: RowsState?
    @State private var editing = false
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var clearedCount: Int?
    /// A layout or switch synced from another device while the page is open.
    @StateObject private var watch = SettingsFieldWatch { f in
        f == "homeRows" || f == "animeCwEnd" || f.hasPrefix("simkl") || f.hasPrefix("cw")
    }

    var body: some View {
        Form {
            Section {
                Button {
                    PhoneFeedback.shared.tap()
                    editing = true
                } label: {
                    Label(T("Edit Home layout"), systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("home-rows-edit")
            } footer: {
                Text(verbatim: T("Add, remove and reorder Home's rows and pick its hero, for this profile."))
            }
            if let s = state {
                if !s.lists.isEmpty {
                    Section {
                        ForEach(s.lists) { list in
                            Toggle(isOn: Binding(get: { list.onHome }, set: { _ in call("homeListRowToggle", [.string(list.id)]) })) {
                                HStack {
                                    Text(verbatim: list.name)
                                    Spacer(minLength: 8)
                                    Text(verbatim: "\(list.count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(verbatim: T("Your lists on Home"))
                    }
                }
                if s.simkl.connected {
                    Section {
                        switchRow("Home rails", on: s.simkl.home) { call("homeSimklRail", [.string("home"), .bool($0)]) }
                        switchRow("Up Next rail", on: s.simkl.upNext) { call("homeSimklRail", [.string("upNext"), .bool($0)]) }
                        switchRow("Trending rail", on: s.simkl.trending) { call("homeSimklRail", [.string("trending"), .bool($0)]) }
                    } header: {
                        Text(verbatim: T("Simkl rails"))
                    }
                }
                if let cw = s.cw {
                    continueWatching(cw)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Home rows"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: watch.tick) { _, _ in Task { await load() } }
        .sheet(isPresented: $editing) {
            PhoneSettingsHomeEditor(app: app) { editing = false }
        }
        .accessibilityIdentifier("settings-home-rows")
    }

    /// library-panel/home-tab.tsx "Continue Watching": cwAdvanceNext, cwHideCaughtUp, animeCwEnd.
    @ViewBuilder private func continueWatching(_ cw: RowsState.Cw) -> some View {
        Section {
            switchRow("Advance Continue Watching to the next episode", on: cw.advanceNext, id: "home-rows-cw-advance") {
                call("homeCwSetting", [.string("advanceNext"), .bool($0)])
            }
            switchRow("Remove shows once you're caught up", on: cw.hideCaughtUp) {
                call("homeCwSetting", [.string("hideCaughtUp"), .bool($0)])
            }
            Picker(selection: Binding(get: { cw.animeCwEnd == "timer" ? "timer" : "hide" },
                                      set: { call("homeCwSetting", [.string("animeCwEnd"), .string($0)]) })) {
                Text(verbatim: T("Hide")).tag("hide")
                Text(verbatim: T("Timer")).tag("timer")
            } label: {
                Text(verbatim: T("When the latest episode ends"))
            }
            Button(role: .destructive) {
                clearedCount = nil
                confirmClear = true
            } label: {
                if clearing { ProgressView() } else { Text(verbatim: T("Clear Continue Watching")) }
            }
            .disabled(clearing)
            .accessibilityIdentifier("home-rows-cw-clear")
            .confirmationDialog(T("Clear Continue Watching"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(T("Clear"), role: .destructive) { Task { await clearContinueWatching() } }
                Button(T("Cancel"), role: .cancel) {}
            } message: {
                Text(verbatim: T("Clear everything you're watching, here and in your Stremio library?"))
            }
        } header: {
            Text(verbatim: T("Continue Watching"))
        } footer: {
            if let n = clearedCount {
                Text(verbatim: n == 1 ? T("Cleared 1 item") : T("Cleared %lld items", n))
            }
        }
    }

    private func switchRow(_ label: String, on: Bool, id: String? = nil, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { next in
            PhoneFeedback.shared.selection()
            set(next)
        })) {
            Text(verbatim: T(label))
        }
        .accessibilityIdentifier(id ?? "home-rows-\(label)")
    }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    private func load() async {
        let p = profile
        // A failed re-read keeps what is on screen.
        if let next: RowsState = try? await HarborEngine.shared.call("rooms.homeRowsState", [p.id, p.linked]) { state = next }
    }

    /// Every edit returns the new state; the engine raises `harbor:home-updated` for Home.
    private func call(_ fn: String, _ args: [AnyJSON]) {
        let p = profile
        Task {
            if let out = try? await HarborEngine.shared.callJSON("rooms.\(fn)", [.string(p.id), .bool(p.linked)] + args),
               let next = try? out.decode(RowsState.self) { state = next }
        }
    }

    /// The TV's "Clear Continue Watching": every item dismissed here and in the Stremio library
    /// (rooms.clearContinueWatching), plus the saved resume frames.
    private func clearContinueWatching() async {
        guard !clearing else { return }
        clearing = true
        let p = ProfilesStore.shared.active
        let authKey: String? = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        let n: Int = (try? await HarborEngine.shared.call("rooms.clearContinueWatching",
            [AnyJSON.string(p?.id ?? "default"), AnyJSON.bool(p?.linked ?? true), authKey.map { AnyJSON.string($0) } ?? AnyJSON.null])) ?? 0
        ExitSnapshotStore.shared.clearAll()
        PhoneFeedback.shared.success()
        clearing = false
        clearedCount = n
    }
}

/// Edit Home opened from Settings: its own loader on the profile's layout, read the way Home reads it.
private struct PhoneSettingsHomeEditor: View {
    let close: () -> Void
    @StateObject private var loader: HomeLayoutLoader

    init(app: AppModel, close: @escaping () -> Void) {
        self.close = close
        _loader = StateObject(wrappedValue: HomeLayoutLoader(PhoneHomeView.dependencies(app: app)))
    }

    var body: some View {
        PhoneHomeEditor(loader: loader, close: close)
            .onDisappear { loader.endAllSources() }
    }
}
