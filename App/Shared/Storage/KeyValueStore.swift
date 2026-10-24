import Foundation

/// The single string key/value surface the engine's `localStorage` shim will talk to.
/// Routes by key: secrets → Keychain, small durable state → UserDefaults, the rest → Caches.
/// Upstream's own key names decide the class, so the tables here grow as modules are ported.
final class KeyValueStore {
    static let shared = KeyValueStore()

    enum Tier { case secret, durable, cache }

    /// Keychain-only keys: the app's own sessions plus upstream's secret-store prefixes
    ///.
    private static let secretPrefixes = ["harbor.auth.", "harbor.theme-session", "harbor.debrid.", "harbor.keys.",
                                         "harbor.trakt.session.v1", "harbor.simkl.session.v1", "harbor.mal.session.v1", "harbor.anilist.session.v1",
                                         "harbor.media-server.token.v1", "harbor.plex-auth.device.v1", "harbor.sports.api-sports.v1",
                                         // engine/aiSearch.ts AI_KEYS_PREFIX: the viewer's OpenRouter / Groq / Jina keys
                                         // (upstream's aiSearchKey / aiGroqKey / jinaKey, kept out of the settings blob).
                                         "harbor.ai-search.keys.v1"]
    /// Small, user-authored state that must survive a cache purge: profiles, settings blobs
    /// (`harbor.settings`, `.shared`, `.<profile>`), sync bookkeeping, sports choices, consent.
    private static let durableKeys: Set<String> = ["harbor.profiles.v1", "harbor.active-profile", "harbor.settings", "harbor.settings.shared", "harbor.sync.account",
                                                   "harbor.sports.favourites.v1", "harbor.sports.sources.v1", "harbor.sports.reminders.v1", "harbor-sports-consent", "harbor.iptv.playlists.v1",
                                                   "harbor.iptv.favorites.v2", "harbor.iptv.pins.v1", "harbor.iptv.epgmap.v1", "harbor.iptv.groupPrefs.v1", "harbor.iptv.countryPrefs.v1", "harbor.iptv.stats.v1",
                                                   "harbor.installed-addons", "harbor.onboarding.bp", "harbor.customlists.v1",
                                                   "harbor.reminders.v1", "harbor.reminders.unseen.v1", "harbor.moviewatched.v1",
                                                   "harbor.media-server.connections.v1", "harbor.media-server.mappings.v1", "harbor.media-server.summaries.v1",
                                                   // lib/player-prefs.ts + lib/subtitles/subtitle-memory.ts: per-show audio/subtitle
                                                   // language, subtitles off, subtitle delay (≤200 shows, ~20 KB); per-episode remembered
                                                   // subtitle (≤500 entries; past Prefs' 64 KB cap `set` moves it to Caches by itself).
                                                   "harbor.player.prefs.v1", "harbor.subtitle.memory.v1",
                                                   // Once synced to the Harbor account, now the TV's only copy:
                                                   // my collections (lib/collections), ratings (lib/ratings/store, the shared/linked
                                                   // key), the pre-profile watchlist (lib/watchlist LEGACY_KEY), watched-by-profile,
                                                   // installed custom themes (no IndexedDB here, so they stay in localStorage), and the
                                                   // layout stores that never had a profile scope (lib/pinned-catalogs,
                                                   // page-collection-rows, detail-customization; page-rows is a prefix below).
                                                   "harbor.collections.v1", "harbor.ratings.v1", "harbor.watchlist.v1", "harbor.watchedby.v1", "harbor.custom-themes.v1",
                                                   "harbor.pinnedcatalogs.v1", "harbor.pagecollrows.v1", "harbor.detailLayout"]
    private static let durablePrefixes = ["harbor.sync.revs", "harbor.sync.idmap", "harbor.settings.", "harbor.installed-addons.", "harbor.tvsettings.v1.",
                                          "harbor.favorites.v1.", "harbor.customlists.v1.", "harbor.localwatchlist.v1.", "harbor.moviewatched.v1.",
                                          // engine/characterFavorites.ts (lib/character-favorites.tsx):
                                          // anime character favourites per profile.
                                          "harbor.charfavorites.v1.",
                                          // views/library/filter-preferences: Media Servers' saved type, server,
                                          // library, genres, sort and direction per profile (a Caches purge reset them).
                                          "harbor.library.filters.",
                                          // Per-profile and legacy forms of the keys above: `harbor.collections.<id>` and
                                          // `harbor.ratings.<id>` (unlinked profiles; also the ratings import receipts),
                                          // lib/watchlist `harbor.watchlist.v1.<id>` (the aggregate cache stays in Caches),
                                          // lib/manual-watched (watched / unwatched / meta / dismissed / fromremote / at, legacy
                                          // keys too), lib/cw-dismiss (`.v1`, `.simkl`), lib/page-rows `harbor.pageRows.<page>`.
                                          // home / anime / nav / services rows live in the settings blob, theme and player
                                          // layout in harbor.tvsettings.v1.*, both already durable.
                                          "harbor.collections.", "harbor.ratings.", "harbor.watchlist.v1.", "harbor.manualwatched.", "harbor.manualunwatched.",
                                          "harbor.cw.dismissed.", "harbor.pageRows."]
    /// Every key the engine may own: upstream uses both `harbor.` and `harbor-` spellings.
    static func isEngineKey(_ key: String) -> Bool { key.hasPrefix("harbor.") || key.hasPrefix("harbor-") }

    /// Lazy namespaces (engine/shims/storage.js LAZY_PREFIXES must match): `snapshot()`
    /// leaves them out and the bundle reads each key with `get` the first time it asks for it. Only
    /// the media-server per-title details and their index: thousands of small Caches files that
    /// every launch read (and the bundle held) though only the Media Servers tab needs them. They
    /// are not memoized here either; the bundle's map holds the ones it has read.
    private static let lazyPrefixes = ["harbor.media-server.meta.v1.", "harbor.media-server.meta-index.v1"]
    static func isLazy(_ key: String) -> Bool { lazyPrefixes.contains(where: key.hasPrefix) }

    private var memory: [String: String] = [:]
    private let lock = NSLock()
    /// Bumped by every set/remove. `get` reads the disk outside the lock (the engine queue
    /// and the main thread both come here), so a slow first read could land after a concurrent write
    /// and pin the old value in `memory` for good; it now caches only when nothing wrote meanwhile.
    private var writes = 0

    static func tier(for key: String) -> Tier {
        if secretPrefixes.contains(where: key.hasPrefix) { return .secret }
        if durableKeys.contains(key) || durablePrefixes.contains(where: key.hasPrefix) { return .durable }
        return .cache
    }

    func get(_ key: String) -> String? {
        lock.lock(); if let v = memory[key] { lock.unlock(); return v }; let seen = writes; lock.unlock()
        let value: String?
        switch Self.tier(for: key) {
        case .secret: value = SecretStore.get(key)
        case .durable: value = Prefs.get(String.self, for: key) ?? CacheStore.shared.get(String.self, for: key)
        case .cache: value = CacheStore.shared.get(String.self, for: key)
        }
        if let value, !Self.skipsMemo(key, value) { lock.lock(); if writes == seen { memory[key] = value }; lock.unlock() }
        return value
    }

    /// `memory` kept a second copy of every value the engine ever wrote, for the
    /// life of the process: the bundle's localStorage shim already holds each one (it is the
    /// source of truth for every engine read), so parsed playlists, catalog and anime caches, the
    /// catalog caches… sat in RAM twice, as UTF-16, with nothing ever trimming them. A large
    /// Caches-tier value that is safely on disk is no longer memoized; Swift reads only a few small
    /// keys (profiles, settings), and a `get` of a big one just reads the file again.
    private static let memoLimit = 16 * 1024

    private static func skipsMemo(_ key: String, _ value: String) -> Bool {
        tier(for: key) == .cache && (isLazy(key) || value.utf16.count >= memoLimit)
    }

    func set(_ value: String, for key: String) throws {
        lock.lock(); memory[key] = value; writes &+= 1; let stamp = writes; lock.unlock()
        switch Self.tier(for: key) {
        case .secret: try SecretStore.set(value, for: key)
        case .durable:
            // One live copy per key: a Caches copy left from before the key was durable (or from an
            // oversize fallback) is dropped, and an oversize value never leaves a stale Prefs copy
            // that `get` would prefer.
            do {
                try Prefs.set(value, for: key)
                if CacheStore.shared.exists(key) { CacheStore.shared.remove(key) }
            } catch {
                Prefs.remove(key)
                try CacheStore.shared.set(value, for: key)
            }
        case .cache:
            try CacheStore.shared.set(value, for: key)
            // On disk now: drop the RAM copy of a big one, unless another write came in meanwhile
            // (a failed write keeps it, so the value still reads back this session).
            if Self.skipsMemo(key, value) {
                lock.lock(); if writes == stamp { memory[key] = nil }; lock.unlock()
            }
        }
    }

    /// Music, Manga and eBook were removed from the app: their sign-ins (Spotify, Last.fm,
    /// Subsonic, Suwayomi), shelves, favourites and reader state are wiped once, from every tier,
    /// so nothing of them lingers in the Keychain or Caches.
    private static let retiredPrefixes = ["harbor.music.", "harbor.manga.", "harbor.mangafav.", "harbor.ebook.", "harbor.spotify.", "harbor.lastfm.", "harbor.subsonic."]
    private static let retiredFlag = "retiredMusicMangaEbook.v1"
    private func purgeRetired() {
        guard !UserDefaults.standard.bool(forKey: Self.retiredFlag) else { return }
        let isRetired: (String) -> Bool = { key in Self.retiredPrefixes.contains(where: key.hasPrefix) }
        for key in CacheStore.shared.allKeys() where isRetired(key) { CacheStore.shared.remove(key) }
        for key in Prefs.allKeys() where isRetired(key) { Prefs.remove(key) }
        for key in SecretStore.allKeys() where isRetired(key) { SecretStore.remove(key) }
        lock.lock()
        for key in memory.keys where isRetired(key) { memory[key] = nil }
        lock.unlock()
        UserDefaults.standard.set(true, forKey: Self.retiredFlag)
    }

    /// The Harbor account is gone (the service shut down), so the TV forgets its session once, before
    /// the engine boots: upstream's theme-auth keeps one per profile (`harbor.theme-session.<profileId>`)
    /// plus the legacy global key and its `.repaired.v2` marker. Only the session goes; local profiles,
    /// settings and lists are untouched, and nothing ever calls the dead server about it.
    private static let harborSessionPrefix = "harbor.theme-session"
    private static let harborSessionFlag = "clearedHarborSession.v1"
    private func purgeHarborSession() {
        guard !UserDefaults.standard.bool(forKey: Self.harborSessionFlag) else { return }
        let isSession: (String) -> Bool = { $0.hasPrefix(Self.harborSessionPrefix) }
        for key in SecretStore.allKeys() where isSession(key) { SecretStore.remove(key) }
        for key in Prefs.allKeys() where isSession(key) { Prefs.remove(key) }
        for key in CacheStore.shared.allKeys() where isSession(key) { CacheStore.shared.remove(key) }
        lock.lock()
        for key in memory.keys where isSession(key) { memory[key] = nil }
        lock.unlock()
        UserDefaults.standard.set(true, forKey: Self.harborSessionFlag)
    }

    /// Every `harbor.*` key/value across all three tiers, in one synchronous pass.
    /// `HarborEngine`'s `__harbor_host.storageSnapshot()` hands this to the bundle at boot so
    /// the JS `localStorage` shim can serve every read from memory. Later tiers win over
    /// earlier ones (an in-memory write is the freshest, then the Keychain / UserDefaults
    /// copy, then a possibly stale Caches copy of the same key). The lazy namespaces are left out.
    func snapshot() -> [String: String] {
        promoteDurableCopies()
        purgeRetired()
        purgeHarborSession()
        var out: [String: String] = [:]
        for key in CacheStore.shared.allKeys() where Self.isEngineKey(key) && !Self.isLazy(key) {
            if let value = CacheStore.shared.get(String.self, for: key) { out[key] = value }
        }
        for key in Prefs.allKeys() where Self.isEngineKey(key) && !Self.isLazy(key) {
            if let value = Prefs.get(String.self, for: key) { out[key] = value }
        }
        for key in SecretStore.allKeys() where Self.isEngineKey(key) && !Self.isLazy(key) {
            if let value = SecretStore.get(key) { out[key] = value }
        }
        lock.lock()
        for (key, value) in memory where Self.isEngineKey(key) && !Self.isLazy(key) { out[key] = value }
        lock.unlock()
        return out
    }

    /// A key that became durable after it was written (the shutdown list above) still has its
    /// only copy in Caches, which tvOS may purge; `set` moves it only on its next write, and a list
    /// nobody edits would never move. Once per launch (`snapshot()` runs at engine boot) each such
    /// copy is written to Prefs, smallest first so the most keys fit the budget, and the Caches copy
    /// is dropped once Prefs holds it. A value Prefs refuses (64 KB per key, the 400 KB budget) stays
    /// where it was, readable as before: tvOS has no other local store that survives a purge.
    private var promoted = false

    private func promoteDurableCopies() {
        lock.lock(); let first = !promoted; promoted = true; lock.unlock()
        guard first else { return }
        let pending = CacheStore.shared.allKeys().filter { Self.isEngineKey($0) && Self.tier(for: $0) == .durable && Prefs.get(String.self, for: $0) == nil }
        let values = pending.compactMap { key in CacheStore.shared.get(String.self, for: key).map { (key: key, value: $0) } }
            .sorted { $0.value.utf8.count < $1.value.utf8.count }
        for item in values {
            guard (try? Prefs.set(item.value, for: item.key)) != nil else { continue }
            CacheStore.shared.remove(item.key)
        }
    }

    /// Every engine key in every tier, lazy ones included, without reading a value
    /// (the bundle's `localStorage.clear()`; `snapshot()` no longer lists the lazy namespaces).
    func engineKeys() -> Set<String> {
        var out = Set<String>()
        for key in CacheStore.shared.allKeys() where Self.isEngineKey(key) { out.insert(key) }
        for key in Prefs.allKeys() where Self.isEngineKey(key) { out.insert(key) }
        for key in SecretStore.allKeys() where Self.isEngineKey(key) { out.insert(key) }
        lock.lock()
        for key in memory.keys where Self.isEngineKey(key) { out.insert(key) }
        lock.unlock()
        return out
    }

    func remove(_ key: String) {
        lock.lock(); memory[key] = nil; writes &+= 1; lock.unlock()
        switch Self.tier(for: key) {
        case .secret: SecretStore.remove(key)
        case .durable: Prefs.remove(key); CacheStore.shared.remove(key)
        case .cache: CacheStore.shared.remove(key)
        }
    }
}
