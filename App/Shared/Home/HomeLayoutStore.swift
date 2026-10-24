import Foundation

/// Where saved layouts live: a string per key. `Prefs` (UserDefaults, survives a Caches purge) on the
/// device; memory under `--fixtures` and in the unit tests.
protocol HomeLayoutStorage: AnyObject {
    func string(for key: String) -> String?
    func set(_ value: String, for key: String) throws
    func remove(_ key: String)
}

/// The app's durable key-value tier. The key has no `harbor.` prefix on purpose: it is the app's
/// own, so it stays out of the engine's localStorage snapshot.
final class PrefsHomeLayoutStorage: HomeLayoutStorage {
    func string(for key: String) -> String? { Prefs.get(String.self, for: key) }
    func set(_ value: String, for key: String) throws { try Prefs.set(value, for: key) }
    func remove(_ key: String) { Prefs.remove(key) }
}

final class MemoryHomeLayoutStorage: HomeLayoutStorage {
    private(set) var values: [String: String] = [:]
    func string(for key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) throws { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}

/// One Home layout per profile, saved as `{"version": 1, "layout": {...}}` under
/// `phone.homeLayout.<profileId>` on the iPhone and `tv.homeLayout.<profileId>` on the Apple TV (each
/// app has its own Prefs; the two never share a layout). No saved layout (or one that cannot be read at all) is the
/// standard layout; rows whose source is unknown are kept as they are (the loader skips them).
@MainActor
final class HomeLayoutStore: ObservableObject {
    static let shared = HomeLayoutStore(storage: Fixtures.active ? MemoryHomeLayoutStorage() : PrefsHomeLayoutStorage())

    /// The layout format written today. A newer version is still read (unknown fields and row kinds
    /// are tolerated); an older one goes through `migrate`.
    static let currentVersion = 1
    #if os(tvOS)
    static let keyPrefix = "tv.homeLayout."
    #else
    static let keyPrefix = "phone.homeLayout."
    #endif

    static func key(for profileId: String) -> String { keyPrefix + profileId }

    private let storage: HomeLayoutStorage
    /// Bumped by every save or reset, so a loader on screen reads the layout again.
    @Published private(set) var revision = 0

    init(storage: HomeLayoutStorage) {
        self.storage = storage
    }

    func layout(for profileId: String) -> HomeLayout {
        guard let raw = storage.string(for: Self.key(for: profileId)) else { return .standard }
        return Self.decode(raw) ?? .standard
    }

    func hasSavedLayout(for profileId: String) -> Bool {
        storage.string(for: Self.key(for: profileId)) != nil
    }

    /// Saving the standard layout clears the key, so a later change to the default reaches it.
    func save(_ layout: HomeLayout, for profileId: String) {
        let key = Self.key(for: profileId)
        if layout.isDefault {
            storage.remove(key)
        } else if let raw = Self.encode(layout) {
            try? storage.set(raw, for: key)
        }
        revision &+= 1
    }

    func reset(for profileId: String) {
        storage.remove(Self.key(for: profileId))
        revision &+= 1
    }

    /// Reads one profile's layout, changes it and saves it.
    func update(for profileId: String, _ change: (inout HomeLayout) -> Void) {
        var layout = layout(for: profileId)
        change(&layout)
        save(layout, for: profileId)
    }

    // MARK: Format

    private struct Envelope: Codable {
        var version: Int
        var layout: HomeLayout
    }

    private struct Version: Decodable { var version: Int? }

    static func encode(_ layout: HomeLayout) -> String? {
        guard let data = try? JSONEncoder().encode(Envelope(version: currentVersion, layout: layout)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String) -> HomeLayout? {
        guard let data = raw.data(using: .utf8) else { return nil }
        let version = (try? JSONDecoder().decode(Version.self, from: data))?.version ?? 0
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return migrate(envelope.layout, from: version)
    }

    /// Version 1 is the first format, so there is nothing to convert yet. A later format change adds a
    /// step here (`if version < 2 { ... }`) and bumps `currentVersion`.
    static func migrate(_ layout: HomeLayout, from version: Int) -> HomeLayout {
        layout
    }
}
