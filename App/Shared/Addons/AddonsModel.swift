import SwiftUI

/// views/addons.tsx on the TV: Discover (spotlight, community rail, categories), Browse
/// (stremio-addons.net by category, Top rated / Top rising / Just added, search) and Installed
/// (position, on/off switch, Manage, Remove, Reorder). Everything runs through the engine's
/// addonsManager (engine/addonsManager.ts), which keeps upstream's rules.
@MainActor
final class AddonsModel: ObservableObject {
    enum Tab: String { case discover, browse, installed }
    /// addons.tsx BROWSE_MODES, in upstream's order.
    enum BrowseMode: String, CaseIterable { case top, rising, new }
    /// community-addons-rail.tsx TABS.
    enum RailMode: String, CaseIterable { case trending, stars, createdAt }

    /// engine/addonsManager.ts AddonCard.
    struct Card: Decodable, Identifiable, Equatable {
        var key: String
        var addonId: String
        var name: String
        var description: String
        var subtitle: String
        var logo: String?
        var background: String?
        var transportUrl: String
        var configureUrl: String
        var installed: Bool
        var configurable: Bool
        @LossyArray var types: [String]   // lossy
        var stars: Double
        var rising: Double?
        var risingWindow: Double?
        var isNew: Bool
        var slug: String?
        var enabled: Bool
        var position: Int
        var id: String { key }
        enum CodingKeys: String, CodingKey {
            case key, addonId = "id", name, description, subtitle, logo, background, transportUrl, configureUrl
            case installed, configurable, types, stars, rising, risingWindow, isNew, slug, enabled, position
        }
    }
    struct Category: Decodable, Identifiable, Equatable { var name: String; var slug: String; var id: String { slug } }
    struct Spotlight: Decodable, Equatable { var addon: Card; var trending: Bool }
    struct Toast: Identifiable, Equatable { let id = UUID(); var ok: Bool; var text: String; var name: String?; var logo: String? }
    struct DetailTarget: Identifiable, Equatable { var id: String }
    /// install-modal.tsx modes plus installer-viewport.tsx: a setup page to finish on the phone
    /// (configure / manage), or a pasted link (url).
    struct ConfigureTarget: Identifiable {
        enum Mode { case configure, manage, url }
        let id = UUID()
        var mode: Mode
        var name: String
        var logo: String?
        var configureUrl: String?
        var manageId: String?
        var prefill = ""
    }

    @Published var tab: Tab = .discover
    @Published private(set) var installed: [Card] = []
    @Published private(set) var installedCount = 0
    @Published private(set) var catalogLoading = false
    @Published private(set) var catalogLoaded = false
    @Published private(set) var categories: [Category] = []
    @Published private(set) var category: String?
    @Published private(set) var mode: BrowseMode = .top
    @Published var query = ""
    @Published private(set) var items: [Card] = []
    @Published private(set) var hasMore = false
    @Published private(set) var browseLoading = false
    @Published private(set) var browseEmpty = "none"
    @Published private(set) var spotlight: Spotlight?
    @Published private(set) var spotlightFailed = false
    @Published private(set) var railMode: RailMode = .trending
    @Published private(set) var rail: [Card]?
    @Published private(set) var busy: Set<String> = []
    @Published var toast: Toast?
    /// The Search screen's install path (install(url:)) reports here.
    @Published var error: String?

    private var page = 1
    private var browseGeneration = 0
    private var catalogGeneration = 0
    private var lastQuery = ""
    private var started = false
    private var toastTask: Task<Void, Never>?

    var authKey: String? { ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey } }
    var adultAllowed: Bool { SettingsBridge.shared.slice.showAdultAddons ?? false }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func start() async {
        guard !started else { return }
        started = true
        async let cats: Void = loadCategories()
        async let disc: Void = loadDiscover()
        await loadCatalog()
        _ = await (cats, disc)
    }

    /// useAddonsCatalog + the Installed tab's order (addons.tsx `installed`).
    func loadCatalog(fresh: Bool = false) async {
        // Numbered: the first visit's slow catalog read finishing after an install's
        // fresh one put the list from before the install back on the Installed tab.
        catalogGeneration += 1
        let gen = catalogGeneration
        catalogLoading = true
        struct Loaded: Decodable { @LossyArray var installed: [Card]; var installedCount: Int; var total: Int; var cached: Bool? }   // lossy
        let r: Loaded? = try? await AddonsEngine.call("addonsManager.load", [authKey, adultAllowed, fresh])
        guard gen == catalogGeneration else { return }
        if let r {
            installed = r.installed
            installedCount = r.installedCount
        }
        catalogLoading = false
        catalogLoaded = true
        // addons.tsx builds the catalog on every visit: the kept one is shown at once,
        // then read again, so an addon added or removed on another Stremio app (or the account
        // list changed elsewhere) appears here without a relaunch.
        if r?.cached == true { await loadCatalog(fresh: true) }
    }

    func loadCategories() async {
        categories = (try? await AddonsEngine.call("addonsManager.categories", [adultAllowed])) ?? []
    }

    func loadDiscover() async {
        spotlightFailed = false
        let s: Spotlight? = try? await AddonsEngine.call("addonsManager.spotlight", [adultAllowed])
        spotlight = s
        spotlightFailed = s == nil
        await loadRail()
    }

    func setRailMode(_ m: RailMode) async {
        guard m != railMode else { return }
        railMode = m
        await loadRail()
    }

    private func loadRail() async {
        rail = nil
        let m = railMode
        let loaded: LossyArray<Card>? = try? await AddonsEngine.call("addonsManager.rail", [m.rawValue, adultAllowed])   // lossy
        let list = loaded?.wrappedValue ?? []
        guard m == railMode else { return }
        rail = list
    }

    // MARK: tabs, filters, search

    func select(_ t: Tab) {
        // addons.tsx: the Browse tab button clears the category.
        if t == .browse && (tab != .browse || category != nil) {
            tab = t
            category = nil
            Task { await reloadBrowse() }
            return
        }
        tab = t
        if t == .browse && items.isEmpty && !browseLoading { Task { await reloadBrowse() } }
    }

    /// category-grid.tsx goToCategory.
    func goToCategory(_ slug: String) {
        category = slug
        tab = .browse
        Task { await reloadBrowse() }
    }

    func setCategory(_ slug: String?) {
        guard slug != category else { return }
        category = slug
        Task { await reloadBrowse() }
    }

    func setMode(_ m: BrowseMode) {
        guard m != mode else { return }
        mode = m
        Task { await reloadBrowse() }
    }

    /// addons.tsx: typing outside Installed moves to Browse; the query replaces the category.
    func queryChanged() async {
        let q = trimmedQuery
        guard q != lastQuery else { return }
        lastQuery = q
        if !q.isEmpty && tab != .installed { tab = .browse }
        if tab == .browse { await reloadBrowse() }
    }

    func reloadBrowse() async {
        browseGeneration += 1
        page = 1
        items = []
        hasMore = true
        browseEmpty = "none"
        await loadMoreBrowse()
    }

    func loadMoreBrowse() async {
        guard !browseLoading, hasMore else { return }
        let gen = browseGeneration
        browseLoading = true
        struct Page: Decodable { @LossyArray var items: [Card]; var hasMore: Bool; var empty: String }   // lossy
        let q = trimmedQuery
        let search: String? = q.isEmpty ? nil : q
        let r: Page? = try? await AddonsEngine.call("addonsManager.browse", [mode.rawValue, category, search, adultAllowed, page])
        // Filters changed while this page loaded: its reload bounced off browseLoading, so it runs now.
        guard gen == browseGeneration else { browseLoading = false; await loadMoreBrowse(); return }
        browseLoading = false
        guard let r else { hasMore = false; return }
        // community-browse-list: a row already shown (same uuid) is not repeated.
        // Also drops repeats inside the page itself (duplicate ForEach ids).
        items = (items + r.items).uniquedById()
        hasMore = r.hasMore && !r.items.isEmpty
        browseEmpty = r.empty
        page += 1
    }

    /// installed-pane.tsx search: name, description or id.
    var filteredInstalled: [Card] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return installed }
        return installed.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) || $0.addonId.lowercased().contains(q) }
    }

    // MARK: install / remove / switches

    struct Outcome: Decodable { var kind: String; var id: String?; var name: String?; var logo: String?; var toast: String?; var configureUrl: String?; var message: String? }

    /// addons.tsx onInstall: a configurable addon comes back as a setup page to open.
    func install(_ card: Card, useDefault: Bool = false) async -> ConfigureTarget? {
        guard !busy.contains(card.key) else { return nil }
        busy.insert(card.key); defer { busy.remove(card.key) }
        let fn = useDefault ? "addonsManager.installDefault" : "addonsManager.install"
        guard let o: Outcome = try? await AddonsEngine.call(fn, [card.addonId, card.transportUrl]) else {
            showToast(false, T("Install failed."))
            return nil
        }
        switch o.kind {
        case "configure":
            return ConfigureTarget(mode: .configure, name: o.name ?? card.name, logo: o.logo ?? card.logo, configureUrl: o.configureUrl ?? card.configureUrl)
        case "installed":
            AddonsEngine.emit("harbor:addons-changed", detail: .object(["id": .string(o.id ?? card.addonId), "installed": .bool(true)]))
            showToast(true, o.toast ?? T("Installed"), name: o.name, logo: o.logo)
            await afterChange()
        default:
            showToast(false, o.message ?? T("Install failed."))
        }
        return nil
    }

    func uninstall(_ card: Card) async {
        guard !busy.contains(card.key) else { return }
        busy.insert(card.key); defer { busy.remove(card.key) }
        struct Removed: Decodable { var ok: Bool; var toast: String }
        let r: Removed? = try? await AddonsEngine.call("addonsManager.uninstall", [card.addonId, card.transportUrl])
        if r?.ok == true {
            AddonsEngine.emit("harbor:addons-changed", detail: .object(["id": .string(card.addonId), "installed": .bool(false)]))
            showToast(true, r?.toast ?? T("Removed"), name: card.name, logo: card.logo)
            await afterChange()
        } else {
            showToast(false, r?.toast ?? T("Couldn't remove. Try again."))
        }
    }

    /// installed-pane.tsx handleToggle.
    func setEnabled(_ card: Card, _ on: Bool) async {
        _ = try? await AddonsEngine.callJSON("addonStore.setAddonEnabled", [.string(card.transportUrl), .bool(on)])
        AddonsEngine.emit("harbor:addons-changed", detail: .object(["id": .string(card.addonId), "enabled": .bool(on)]))
        if let i = installed.firstIndex(where: { $0.key == card.key }) { installed[i].enabled = on }
    }

    /// After an install from a pasted or phone-sent link (configure / manage / URL).
    func installedFromLink(id: String, name: String?, logo: String?, toast text: String) async {
        AddonsEngine.emit("harbor:addons-changed", detail: .object(["id": .string(id), "installed": .bool(true)]))
        showToast(true, text, name: name, logo: logo)
        await afterChange()
    }

    /// The Organize page saved: re-read the Installed order.
    func reordered(toast text: String) async {
        AddonsEngine.emit("harbor:addons-changed", detail: .object(["reordered": .bool(true)]))
        showToast(true, text)
        await loadCatalog(fresh: true)
    }

    /// refetch(): the catalog, and the install flags on the lists already on screen.
    private func afterChange() async {
        await loadCatalog(fresh: true)
        let ids = Set(installed.map(\.addonId))
        for i in items.indices { items[i].installed = ids.contains(items[i].addonId) }
        if var s = spotlight { s.addon.installed = ids.contains(s.addon.addonId); spotlight = s }
        rail = rail?.filter { !ids.contains($0.addonId) }
    }

    /// addons.tsx Adult chip: on only after the age check (AgeGateView), off at once.
    func setAdult(_ on: Bool) async {
        try? await SettingsBridge.shared.patch(["showAdultAddons": .bool(on)])
        if !on && category == "nsfw" { category = nil }
        await loadCategories()
        async let disc: Void = loadDiscover()
        await loadCatalog(fresh: true)
        if tab == .browse || !items.isEmpty { await reloadBrowse() }
        _ = await disc
    }

    /// addons.tsx showToast: 3 s for a success, 5 s for an error.
    func showToast(_ ok: Bool, _ text: String, name: String? = nil, logo: String? = nil) {
        toastTask?.cancel()
        let t = Toast(ok: ok, text: text, name: name, logo: logo)
        withAnimation(BP.easeFast) { toast = t }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ok ? 3_000_000_000 : 5_000_000_000)
            guard !Task.isCancelled, let self, self.toast?.id == t.id else { return }
            withAnimation(BP.easeFast) { self.toast = nil }
        }
    }

    /// The Search screen's "hold Select to install" path: straight to installFromUrl.
    func install(url: String) async -> Bool {
        error = nil
        do {
            struct Result: Decodable { var replaced: Bool; var syncedToStremio: Bool }
            let _: Result = try await AddonsEngine.call("addonStore.installFromUrl", [url])
            AddonsEngine.emit("harbor:addons-changed")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
