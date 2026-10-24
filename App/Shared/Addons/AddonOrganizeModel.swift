import SwiftUI

/// The state and engine calls behind the addon organizer: the
/// Stremio account's addon order and the addons that live only on this device, each reordered and
/// saved with upstream's checks (validate, re-read for changes made elsewhere, back up, write, read
/// back) by the engine (addonsManager.organize*). AddonOrganizeView draws it with the remote's
/// focus ring; the phone's organizer will draw over the same model.
///
/// Every property is @Published where it was @State, so a write redraws the view exactly as before.
/// The one thing the view keeps is the focus ring (a @FocusState); the model reaches it through
/// `bindFocus`.
@MainActor
final class AddonOrganizeModel: ObservableObject {
    struct Row: Decodable, Identifiable, Equatable { var key: String; var name: String; var host: String; var addonId: String; var logo: String?; var id: String { key } }
    struct Loaded: Decodable { var ok: Bool; var signedIn: Bool; var cloud: [Row]; var device: [Row]; var backups: Int }
    struct Backup: Decodable, Identifiable { var index: Int; var at: Double; var count: Int; var names: [String]; var id: Int { index } }
    struct Notice { var danger: Bool; var text: String; var retry = false; var reload = false }
    enum Section { case cloud, device }
    struct MoveMark: Equatable { var key: String; var tick: Int }

    let authKey: String?
    /// The caller's "saved" toast (the organizer closes itself through its own onClose).
    private let onSaved: (String) -> Void

    @Published var loading = true
    /// The first read has answered. Reload list, Try again and Move all to
    /// account read again: they swapped the whole page for the spinner, so the ring on the button
    /// just pressed fell to the header (Cancel / Save order), and stayed there after the list came back.
    @Published var settled = false
    @Published var loadError = false
    @Published var signedIn = false
    @Published var baselineCloud: [Row] = []
    @Published var baselineDevice: [Row] = []
    @Published var cloud: [Row] = []
    @Published var device: [Row] = []
    @Published var saving: String?
    @Published var moving = false
    @Published var notice: Notice?
    @Published var grabbed: String?
    @Published var backupsOpen = false
    @Published var backups: [Backup] = []
    /// `moved` scrolls the list after a moved row (the focus engine only scrolls on
    /// focus changes, so a row carried past the screen edge used to leave the view behind).
    @Published var moved: MoveMark?

    var dirty: Bool { cloud != baselineCloud || device != baselineDevice }
    var locked: Bool { saving != nil || moving }

    // MARK: focus ring (the view's @FocusState, bound through closures)

    private var focusReader: () -> String? = { nil }
    private var focusWriter: (String?) -> Void = { _ in }
    /// Focus is bound to the row key, not its index, so a picked-up row keeps focus as
    /// it moves. Both go to the view's @FocusState.
    var focusedRow: String? {
        get { focusReader() }
        set { focusWriter(newValue) }
    }

    /// The view hands over its @FocusState (capturing only the state, never the view or the model).
    func bindFocus(read: @escaping () -> String?, write: @escaping (String?) -> Void) {
        focusReader = read
        focusWriter = write
    }

    init(authKey: String?, onSaved: @escaping (String) -> Void) {
        self.authKey = authKey
        self.onSaved = onSaved
    }

    // MARK: edits

    /// reorder.ts moveItem: clamp the target, splice the row out and back in.
    func move(_ which: Section, from: Int, to: Int) {
        var list = which == .cloud ? cloud : device
        let target = max(0, min(list.count - 1, to))
        guard from >= 0, from < list.count, from != target else { return }
        let item = list.remove(at: from)
        list.insert(item, at: target)
        withAnimation(BP.easeFast) {
            if which == .cloud { cloud = list } else { device = list }
        }
        // The ForEach is keyed by row id, so the moved row keeps its focus; say so
        // explicitly for a picked-up row, and bring the row's new place into view.
        // A row sent to either end disables the arrow just pressed (Move up / Move to
        // top at the top, Move down at the bottom), which dropped the focus ring to wherever the
        // focus engine found; it goes to the moved row instead.
        if grabbed == item.key || target == 0 || target == list.count - 1 { focusedRow = item.key }
        moved = MoveMark(key: item.key, tick: (moved?.tick ?? 0) + 1)
    }

    /// Back / Menu: drops a picked-up row, then the backups panel, then (when idle) asks to close.
    /// Returns true when the page should close.
    func backPressed() -> Bool {
        if grabbed != nil { grabbed = nil; return false }
        if backupsOpen { backupsOpen = false; return false }
        return !locked
    }

    /// The Backups button: opens or closes the panel, reading the list on open.
    func toggleBackups() {
        backupsOpen.toggle()
        if backupsOpen { Task { await loadBackups() } }
    }

    // MARK: engine

    /// `reset`: a new visit (the backup-before-first-write starts over); Reload / Try again keep it.
    func load(reset: Bool = false) async {
        loading = true; defer { loading = false; settled = true }
        notice = nil; grabbed = nil
        guard let r: Loaded = try? await AddonsEngine.call("addonsManager.organizeLoad", [authKey, reset]) else { loadError = true; return }
        loadError = !r.ok
        signedIn = r.signedIn
        baselineCloud = r.cloud; cloud = r.cloud
        baselineDevice = r.device; device = r.device
        // A re-read from a button that is gone now (Reload list and Try again
        // leave with their panels, Move all to account with the emptied device section) hands the
        // ring to the first row, as Restore does.
        if !reset, r.ok, focusedRow == nil { focusedRow = (cloud.first ?? device.first)?.key }
        if backupsOpen || r.backups > 0 { await loadBackups() }
    }

    func loadBackups() async {
        backups = (try? await AddonsEngine.call("addonsManager.organizeBackups", [])) ?? []
    }

    func save() async {
        guard dirty, saving == nil else { return }
        notice = nil; grabbed = nil
        saving = cloud != baselineCloud ? "checking" : "saving"
        defer { saving = nil }
        struct Saved: Decodable { var ok: Bool; var scope: String?; var toast: String?; var tone: String?; var text: String?; var retry: Bool?; var reload: Bool? }
        let r: Saved? = try? await AddonsEngine.call("addonsManager.organizeSave", [cloud.map(\.key), device.map(\.key)])
        guard let r else {
            notice = Notice(danger: true, text: T("Something unexpected went wrong. Nothing may have been written. Retry to re-check."), retry: true)
            return
        }
        if r.ok {
            onSaved(r.toast ?? T("Addon order saved on this device"))
        } else {
            notice = Notice(danger: r.tone != "info", text: r.text ?? "", retry: r.retry ?? false, reload: r.reload ?? false)
            await loadBackups()
        }
    }

    func moveAll() async {
        guard !locked, !dirty else { return }
        moving = true; defer { moving = false }
        struct Moved: Decodable { var ok: Bool; var text: String; var reload: Bool }
        guard let r: Moved = try? await AddonsEngine.call("addonsManager.organizeMoveAll", []), !r.text.isEmpty else { return }
        if r.ok { await load() }
        notice = Notice(danger: !r.ok, text: r.text, reload: r.reload)
        await loadBackups()
    }

    func backupNow() async {
        struct Out: Decodable { var ok: Bool; var text: String }
        guard let r: Out = try? await AddonsEngine.call("addonsManager.organizeBackupNow", [cloud.map(\.key)]), r.ok else { return }
        notice = Notice(danger: false, text: r.text)
        await loadBackups()
    }

    func restore(_ index: Int) async {
        struct Out: Decodable { var keys: [String]; var text: String }
        guard let r: Out = try? await AddonsEngine.call("addonsManager.organizeRestore", [index]) else { return }
        let byKey = Dictionary(uniqueKeysWithValues: baselineCloud.map { ($0.key, $0) })
        cloud = r.keys.compactMap { byKey[$0] }
        backupsOpen = false
        notice = Notice(danger: false, text: r.text)
        // The panel closes under the Restore just pressed: focus goes to the
        // restored list's first row rather than wherever the focus engine lands.
        focusedRow = cloud.first?.key
    }
}
