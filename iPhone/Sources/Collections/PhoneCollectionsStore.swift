import SwiftUI

/// Where the viewer's own collections are kept: the engine's `collectionsRoom` (upstream
/// lib/collections over the shared localStorage), the same store the TV's Collections room edits, so
/// a change made on either shows on the other. A protocol so the unit tests can run on a fake.
@MainActor
protocol PhoneCollectionsBackend {
    func mine() async throws -> [CollectionsModel.Card]
    func limits() async -> CollectionsModel.Limits?
    /// nil when the collection cap is reached.
    func create(_ name: String) async throws -> CollectionsModel.Card?
    func rename(_ ref: String, _ name: String) async throws -> CollectionsModel.Card?
    func remove(_ ref: String) async throws
    func addItem(_ ref: String, _ item: CollectionsModel.Item) async throws -> CollectionsModel.Card?
    func removeItem(_ ref: String, _ itemId: String) async throws -> CollectionsModel.Card?
    func reorderItems(_ ref: String, _ itemIds: [String]) async throws -> CollectionsModel.Card?
    /// The viewer's collections in this order; returns them as the engine now lists them.
    func reorder(_ refs: [String]) async throws -> [CollectionsModel.Card]
}

/// The engine glue (engine/collections.ts).
struct EngineCollectionsBackend: PhoneCollectionsBackend {
    private struct NewItem: Encodable { var id: String; var type: String; var name: String; var poster: String? }

    func mine() async throws -> [CollectionsModel.Card] {
        let got: LossyArray<CollectionsModel.Card> = try await HarborEngine.shared.call("collectionsRoom.mine", [])
        return got.wrappedValue
    }

    func limits() async -> CollectionsModel.Limits? {
        try? await HarborEngine.shared.call("collectionsRoom.limits", [])
    }

    func create(_ name: String) async throws -> CollectionsModel.Card? {
        try await HarborEngine.shared.call("collectionsRoom.create", [name])
    }

    func rename(_ ref: String, _ name: String) async throws -> CollectionsModel.Card? {
        try await HarborEngine.shared.call("collectionsRoom.rename", [ref, name])
    }

    func remove(_ ref: String) async throws {
        _ = try await HarborEngine.shared.callJSON("collectionsRoom.remove", [.string(ref)])
    }

    func addItem(_ ref: String, _ item: CollectionsModel.Item) async throws -> CollectionsModel.Card? {
        let new = NewItem(id: item.id, type: item.type, name: item.name, poster: item.poster)
        return try await HarborEngine.shared.call("collectionsRoom.addItem", [ref, new])
    }

    func removeItem(_ ref: String, _ itemId: String) async throws -> CollectionsModel.Card? {
        try await HarborEngine.shared.call("collectionsRoom.removeItem", [ref, itemId])
    }

    func reorderItems(_ ref: String, _ itemIds: [String]) async throws -> CollectionsModel.Card? {
        try await HarborEngine.shared.call("collectionsRoom.reorderItems", [ref, itemIds])
    }

    func reorder(_ refs: [String]) async throws -> [CollectionsModel.Card] {
        let got: LossyArray<CollectionsModel.Card> = try await HarborEngine.shared.call("collectionsRoom.reorder", [refs])
        return got.wrappedValue
    }
}

/// The viewer's own collections on the phone: the grid, a
/// collection's page, edit mode and the poster menu's "Add to collection" all read and change them
/// here. Every change shows at once and is then saved through the engine; the engine's answer is what
/// stays. A change the engine refuses is undone by reading the collections again, with a toast.
@MainActor
final class PhoneCollectionsStore: ObservableObject {
    static let shared = PhoneCollectionsStore(backend: EngineCollectionsBackend())

    /// In the viewer's order (engine/collections.ts `ordered`): the ones made since the last reorder lead.
    @Published private(set) var mine: [CollectionsModel.Card] = []
    @Published private(set) var limits = CollectionsModel.Limits(collections: 24, items: 100)
    @Published private(set) var loaded = false
    @Published private(set) var failed = false

    private let backend: PhoneCollectionsBackend
    private var loading = false
    /// Bumped by every change, so an answer that a later change has overtaken is not drawn.
    private var revision = 0
    private var fixtureInstalled = false

    /// The profile the list was read for: a profile with its own settings has its own collections.
    private var loadedFor: String?
    private let profile: @MainActor () -> String?

    init(backend: PhoneCollectionsBackend, profile: @escaping @MainActor () -> String? = { ProfilesStore.shared.activeId }) {
        self.backend = backend
        self.profile = profile
    }

    /// upstream MAX_COLLECTION_NAME: renameCollection keeps the first 80 characters.
    static let maxName = 80

    var canCreate: Bool { mine.count < limits.collections }

    func card(_ ref: String) -> CollectionsModel.Card? { mine.first { $0.ref == ref } }

    func contains(_ itemId: String, in ref: String) -> Bool {
        card(ref)?.items.contains { $0.id == itemId } ?? false
    }

    /// Titles a collection can hold: films and shows (the TV's add search offers those too).
    static func collectable(_ meta: Meta) -> Bool { meta.type == "movie" || meta.type == "series" }

    // MARK: Reading

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if PhoneLaunch.collectionsFixture && !fixtureInstalled {
            fixtureInstalled = true
            await installFixture()
        }
        let at = revision
        let who = profile()
        if let got = await backend.limits() { limits = got }
        do {
            let got = try await backend.mine()
            guard at == revision else { return }
            mine = got
            loadedFor = who
            failed = false
        } catch {
            failed = true
        }
        loaded = true
    }

    /// The first screen that needs the collections reads them; later ones reuse what is here until
    /// the profile changes. (The Collections grid reads them afresh each time it opens, for the TV's edits.)
    func ensureLoaded() {
        guard !loading, !PhoneLaunch.hostsUnitTests else { return }
        guard !loaded || loadedFor != profile() else { return }
        Task { await load() }
    }

    // MARK: Collections

    /// community-hub "New collection": the new one leads the grid. nil at the cap.
    @discardableResult
    func create(name: String) async -> CollectionsModel.Card? {
        guard canCreate else {
            PhoneToaster.shared.show(T("You can have up to %lld collections.", limits.collections))
            return nil
        }
        revision += 1
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxName))
        do {
            guard let made = try await backend.create(trimmed) else {
                PhoneToaster.shared.show(T("You can have up to %lld collections.", limits.collections))
                return nil
            }
            mine.removeAll { $0.ref == made.ref }
            mine.insert(made, at: 0)
            PhoneFeedback.shared.success()
            return made
        } catch {
            await refused()
            return nil
        }
    }

    func rename(_ ref: String, to name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxName))
        guard !trimmed.isEmpty, let at = mine.firstIndex(where: { $0.ref == ref }), mine[at].name != trimmed else { return }
        revision += 1
        mine[at].name = trimmed
        await save(ref) { try await self.backend.rename(ref, trimmed) }
    }

    func delete(_ ref: String) async {
        guard mine.contains(where: { $0.ref == ref }) else { return }
        revision += 1
        mine.removeAll { $0.ref == ref }
        do {
            try await backend.remove(ref)
        } catch {
            await refused()
        }
    }

    /// Edit mode's drag (List.onMove offsets).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var next = mine
        next.move(fromOffsets: source, toOffset: destination)
        await reorder(next.map(\.ref))
    }

    /// The viewer's collections in this order (refs it does not name keep their place after these).
    func reorder(_ refs: [String]) async {
        var next: [CollectionsModel.Card] = refs.compactMap { ref in mine.first { $0.ref == ref } }
        next += mine.filter { !refs.contains($0.ref) }
        guard next.map(\.ref) != mine.map(\.ref) else { return }
        revision += 1
        let at = revision
        mine = next
        do {
            let got = try await backend.reorder(next.map(\.ref))
            if at == revision { mine = got }
        } catch {
            await refused()
        }
    }

    // MARK: Titles

    /// Adds the title, or takes it out when it is already there. Returns whether it is in now.
    @discardableResult
    func toggle(_ meta: Meta, in ref: String) async -> Bool {
        if contains(meta.id, in: ref) {
            await remove(meta.id, from: ref)
            return false
        }
        return await add(meta, to: ref)
    }

    @discardableResult
    func add(_ meta: Meta, to ref: String) async -> Bool {
        guard let at = mine.firstIndex(where: { $0.ref == ref }) else { return false }
        if mine[at].items.contains(where: { $0.id == meta.id }) { return true }
        // Manga the TV does not show still count toward upstream's cap.
        guard mine[at].items.count + (mine[at].hidden ?? 0) < limits.items else {
            PhoneToaster.shared.show(T("This collection is full."))
            return false
        }
        revision += 1
        let item = CollectionsModel.Item(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster)
        mine[at].items.append(item)
        mine[at].count = mine[at].items.count
        if mine[at].image == nil { mine[at].image = meta.poster }
        await save(ref) { try await self.backend.addItem(ref, item) }
        return true
    }

    func remove(_ itemId: String, from ref: String) async {
        guard let at = mine.firstIndex(where: { $0.ref == ref }), mine[at].items.contains(where: { $0.id == itemId }) else { return }
        revision += 1
        mine[at].items.removeAll { $0.id == itemId }
        mine[at].count = mine[at].items.count
        await save(ref) { try await self.backend.removeItem(ref, itemId) }
    }

    /// Edit mode's swipe or delete button on a collection's titles.
    func removeItems(atOffsets offsets: IndexSet, from ref: String) async {
        guard let card = card(ref) else { return }
        for id in offsets.compactMap({ card.items.indices.contains($0) ? card.items[$0].id : nil }) {
            await remove(id, from: ref)
        }
    }

    /// Edit mode's drag of a collection's titles.
    func moveItems(in ref: String, fromOffsets source: IndexSet, toOffset destination: Int) async {
        guard let at = mine.firstIndex(where: { $0.ref == ref }) else { return }
        var items = mine[at].items
        items.move(fromOffsets: source, toOffset: destination)
        let ids = items.map(\.id)
        guard ids != mine[at].items.map(\.id) else { return }
        revision += 1
        mine[at].items = items
        await save(ref) { try await self.backend.reorderItems(ref, ids) }
    }

    // MARK: Saving

    /// Runs one collection's change; the engine's answer replaces the card unless a later change
    /// came in meanwhile (its own answer follows).
    private func save(_ ref: String, _ change: @escaping () async throws -> CollectionsModel.Card?) async {
        let at = revision
        do {
            let got = try await change()
            guard at == revision else { return }
            if let got, let i = mine.firstIndex(where: { $0.ref == ref }) {
                mine[i] = got
            } else if got == nil {
                // The engine no longer has it (deleted on the TV): read the list again.
                await reload()
            }
        } catch {
            await refused()
        }
    }

    private func refused() async {
        PhoneFeedback.shared.warning()
        PhoneToaster.shared.show(T("Couldn't save that change."))
        await reload()
    }

    private func reload() async {
        revision += 1
        if let got = try? await backend.mine() { mine = got }
    }

    // MARK: UI-test fixture

    /// `--phone-collections`: three collections of the fixture titles in a known order, made through
    /// the engine (so the UI test runs the real reorder and edits), replacing whatever a past run left.
    static let fixture: [(name: String, items: [(id: String, type: String, name: String)])] = [
        ("Weekend Movies", [("tt0133093", "movie", "The Matrix"), ("tt0816692", "movie", "Interstellar"),
                            ("tt1375666", "movie", "Inception"), ("tt0468569", "movie", "The Dark Knight")]),
        ("Sci-Fi Favourites", [("tt0083658", "movie", "Blade Runner"), ("tt0062622", "movie", "2001: A Space Odyssey"),
                               ("tt0088763", "movie", "Back to the Future")]),
        ("Comfort Shows", [("tt0108778", "series", "Friends"), ("tt0386676", "series", "The Office")]),
    ]

    private func installFixture() async {
        revision += 1
        for card in (try? await backend.mine()) ?? [] { try? await backend.remove(card.ref) }
        var refs: [String] = []
        for entry in Self.fixture {
            guard let made = try? await backend.create(entry.name) else { continue }
            refs.append(made.ref)
            for item in entry.items {
                _ = try? await backend.addItem(made.ref, CollectionsModel.Item(id: item.id, type: item.type, name: item.name, poster: nil))
            }
        }
        _ = try? await backend.reorder(refs)
    }
}
