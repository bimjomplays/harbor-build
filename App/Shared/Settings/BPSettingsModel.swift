import SwiftUI

/// bp-settings.tsx: a category column (label + summary) and, for the active category, the
/// control rows from upstream's catalog: option rails, multi cells, push rows and actions.
@MainActor
final class BPSettingsModel: ObservableObject {
    struct Category: Decodable, Identifiable, Equatable { var id: String; var label: String; var summary: String }
    struct Option: Decodable, Identifiable, Equatable { var value: String; var label: String; var id: String { value } }
    struct MultiItem: Decodable, Identifiable, Equatable { var value: String; var label: String; var on: Bool; var rank: Int; var tint: String?; var id: String { value } }
    struct Control: Decodable, Identifiable, Equatable {
        var kind: String; var id: String; var label: String
        var value: String?; var options: [Option]?; var letter: Bool?; var columns: Int?
        var render: String?; var items: [MultiItem]?
        var detail: String?; var pane: String?
    }
    struct Cats: Decodable { var categories: [Category]; var sportsShown: Bool; var overscan: Double }
    struct Committed: Decodable { var ok: Bool; var sportsShown: Bool }

    /// engine settingsRoom.pane: what bp-settings-pane.tsx draws beside the column.
    struct Pane: Decodable, Equatable {
        struct Subtitle: Decodable, Equatable { var text: String; var px: Double; var flags: [String] }
        struct Service: Decodable, Identifiable, Equatable { var value: String; var label: String; var tint: String; var id: String { value } }
        struct Language: Decodable, Equatable { var code: String; var nativeLabel: String; var greeting: String; var rtl: Bool }
        var still: String
        var overscan: Double
        var overscanLabel: String
        var subtitle: Subtitle
        var homeMode: String
        var services: [Service]
        var servicesEmpty: String
        var language: Language?
        var playback: [[String]]
        var setup: [[String]]
        var interface: [[String]]
    }

    /// A theme change rebuilds the tree (ThemeStore.revision); the column comes back where it was.
    private static var lastActive = "picture"

    @Published private(set) var categories: [Category] = []
    @Published private(set) var controls: [Control] = []
    @Published private(set) var pane: Pane?
    @Published var active: String = BPSettingsModel.lastActive

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    /// Only the newest load applies: a commit, harbor:settings-updated and a
    /// closing cover can each start one, and an older answer landing last put old values back.
    private var loadGen = 0
    private var unsubscribe: (() -> Void)?
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel(); unsubscribe?() }

    func load() async {
        watch()
        loadGen &+= 1
        let gen = loadGen
        let p = profile
        let c: Cats? = try? await HarborEngine.shared.call("settingsRoom.categories", [p.id, p.linked])
        guard gen == loadGen else { return }
        if let c {
            if c.categories != categories { categories = c.categories }
            let declined = !c.sportsShown
            if SettingsBridge.shared.sportsDeclined != declined { SettingsBridge.shared.sportsDeclined = declined }
        }
        let fresh: Pane? = try? await HarborEngine.shared.call("settingsRoom.pane", [p.id, p.linked])
        guard gen == loadGen else { return }
        if let fresh, fresh != pane { pane = fresh }
        await loadControls()
    }

    /// bp-settings.tsx reads the live settings on every render, so a change
    /// synced from another device (profile sync raises harbor:settings-updated) shows at once. The
    /// column loaded once per visit and kept the old values, summaries and preview; a burst of
    /// events (one per synced section) now reloads once.
    private func watch() {
        guard unsubscribe == nil else { return }
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
            guard type == "harbor:settings-updated" else { return }
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func loadControls() async {
        let p = profile
        let id = active
        let fresh: [Control]? = try? await HarborEngine.shared.call("settingsRoom.controls", [id, p.id, p.linked])
        // Focus can walk the column faster than the engine answers; only the latest wins.
        guard id == active, let fresh, fresh != controls else { return }
        controls = fresh
    }

    /// The chosen category's rows, loaded now if the focus walk has not brought them in yet.
    func ensureControls() async {
        if controls.isEmpty { await loadControls() }
    }

    func select(_ id: String) {
        guard id != active || controls.isEmpty else { return }
        // bp-settings.tsx: leaving the category puts the committed sound theme back.
        Platform.feedback.audition = nil
        // upstream derives the rows from the active category in the same
        // render; here they arrive later, and Select pressed before they did opened the previous
        // category's rows (and a press there changed that category's setting).
        if id != active { controls = [] }
        active = id
        Self.lastActive = id
        Task { await loadControls() }
    }

    func commit(_ control: String, _ value: String) async {
        let p = profile
        if let c: Committed = try? await HarborEngine.shared.call("settingsRoom.commit", [control, value, p.id, p.linked]) {
            let declined = !c.sportsShown
            if SettingsBridge.shared.sportsDeclined != declined { SettingsBridge.shared.sportsDeclined = declined }
        }
        await SettingsBridge.shared.load()
        Platform.feedback.audition = nil
        await load()
    }
}
