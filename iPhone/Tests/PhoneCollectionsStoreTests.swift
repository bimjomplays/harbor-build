import XCTest
@testable import HarborPhone

/// The engine's collections store as engine/collections.ts and upstream lib/collections keep it:
/// newest-edited first, the viewer's own order (`reorder`) over that, new ones leading, the caps, and
/// reorderCollectionItems' "named first, the rest after". In memory, so a second store over the same
/// backend stands for the next launch (or the TV reading the same store).
@MainActor
final class MemoryCollectionsBackend: PhoneCollectionsBackend {
    struct Stored { var id: String; var name: String; var items: [CollectionsModel.Item]; var updatedAt: Int }

    var stored: [Stored] = []
    var order: [String] = []
    var maxCollections = 24
    var maxItems = 100
    /// The next call throws, as an engine that refuses the change.
    var failNext = false
    private var clock = 0
    private var made = 0

    private func tick() -> Int { clock += 1; return clock }

    private func check() throws {
        if failNext {
            failNext = false
            throw URLError(.cannotWriteToFile)
        }
    }

    private func card(_ s: Stored) -> CollectionsModel.Card {
        CollectionsModel.Card(key: "mine:\(s.id)", source: "mine", ref: s.id, name: s.name, image: s.items.first?.poster,
                              count: s.items.count, byline: nil, description: nil, items: s.items, hidden: 0)
    }

    private func cardFor(_ id: String) -> CollectionsModel.Card? { stored.first { $0.id == id }.map { self.card($0) } }

    func mine() async throws -> [CollectionsModel.Card] {
        try check()
        let newest = stored.sorted { $0.updatedAt > $1.updatedAt }
        let fresh = newest.filter { !order.contains($0.id) }
        let placed = newest.filter { order.contains($0.id) }.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        return (fresh + placed).map { self.card($0) }
    }

    func limits() async -> CollectionsModel.Limits? { .init(collections: maxCollections, items: maxItems) }

    func create(_ name: String) async throws -> CollectionsModel.Card? {
        try check()
        guard stored.count < maxCollections else { return nil }
        made += 1
        let s = Stored(id: "c\(made)", name: name.isEmpty ? "Untitled collection" : name, items: [], updatedAt: tick())
        stored.append(s)
        return card(s)
    }

    func rename(_ ref: String, _ name: String) async throws -> CollectionsModel.Card? {
        try check()
        guard let i = stored.firstIndex(where: { $0.id == ref }) else { return nil }
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(80))
        if !trimmed.isEmpty { stored[i].name = trimmed; stored[i].updatedAt = tick() }
        return cardFor(ref)
    }

    func remove(_ ref: String) async throws {
        try check()
        stored.removeAll { $0.id == ref }
        order.removeAll { $0 == ref }
    }

    func addItem(_ ref: String, _ item: CollectionsModel.Item) async throws -> CollectionsModel.Card? {
        try check()
        guard let i = stored.firstIndex(where: { $0.id == ref }) else { return nil }
        if stored[i].items.count < maxItems && !stored[i].items.contains(where: { $0.id == item.id }) {
            stored[i].items.append(item)
            stored[i].updatedAt = tick()
        }
        return cardFor(ref)
    }

    func removeItem(_ ref: String, _ itemId: String) async throws -> CollectionsModel.Card? {
        try check()
        guard let i = stored.firstIndex(where: { $0.id == ref }) else { return nil }
        stored[i].items.removeAll { $0.id == itemId }
        stored[i].updatedAt = tick()
        return cardFor(ref)
    }

    func reorderItems(_ ref: String, _ itemIds: [String]) async throws -> CollectionsModel.Card? {
        try check()
        guard let i = stored.firstIndex(where: { $0.id == ref }) else { return nil }
        let items = stored[i].items
        var next = itemIds.compactMap { id in items.first { $0.id == id } }
        next += items.filter { !itemIds.contains($0.id) }
        stored[i].items = next
        stored[i].updatedAt = tick()
        return cardFor(ref)
    }

    func reorder(_ refs: [String]) async throws -> [CollectionsModel.Card] {
        try check()
        var ids: [String] = []
        for ref in refs where stored.contains(where: { $0.id == ref }) && !ids.contains(ref) { ids.append(ref) }
        order = ids
        return try await mine()
    }
}

@MainActor
final class PhoneCollectionsStoreTests: XCTestCase {
    private func meta(_ id: String, _ type: String = "movie") -> Meta {
        CollectionsModel.Item(id: id, type: type, name: "Title \(id)", poster: nil).meta
    }

    private func store(_ backend: MemoryCollectionsBackend) -> PhoneCollectionsStore {
        PhoneCollectionsStore(backend: backend, profile: { "p1" })
    }

    private func names(_ store: PhoneCollectionsStore) -> [String] { store.mine.map(\.name) }

    /// Three collections made A, B, C: the newest leads, as upstream lists them.
    private func three(_ backend: MemoryCollectionsBackend) async -> PhoneCollectionsStore {
        let s = store(backend)
        await s.load()
        await s.create(name: "A")
        await s.create(name: "B")
        await s.create(name: "C")
        return s
    }

    func testNewCollectionsLead() async {
        let backend = MemoryCollectionsBackend()
        let s = await three(backend)
        XCTAssertEqual(names(s), ["C", "B", "A"])
        await s.load()
        XCTAssertEqual(names(s), ["C", "B", "A"])
    }

    func testDragReorderIsSavedForTheNextLaunch() async {
        let backend = MemoryCollectionsBackend()
        let s = await three(backend)
        // Drag C (first) to the end.
        await s.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(names(s), ["B", "A", "C"])
        XCTAssertEqual(backend.order, s.mine.map(\.ref))
        let next = store(backend)
        await next.load()
        XCTAssertEqual(names(next), ["B", "A", "C"])
    }

    func testMenuMoveUpAndDown() async {
        let backend = MemoryCollectionsBackend()
        let s = await three(backend)
        // The context menu's Move down on the first, then Move up on the last.
        await s.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(names(s), ["B", "C", "A"])
        await s.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(names(s), ["B", "A", "C"])
    }

    func testAnEditDoesNotUndoTheOrder() async {
        let backend = MemoryCollectionsBackend()
        let s = await three(backend)
        await s.reorder(s.mine.reversed().map(\.ref))
        XCTAssertEqual(names(s), ["A", "B", "C"])
        // Renaming or filling C makes it the newest edit; the viewer's order still holds.
        let c = s.mine[2].ref
        await s.rename(c, to: "C2")
        _ = await s.add(meta("tt1"), to: c)
        XCTAssertEqual(names(s), ["A", "B", "C2"])
        await s.load()
        XCTAssertEqual(names(s), ["A", "B", "C2"])
        // One made after the reorder leads.
        await s.create(name: "D")
        await s.load()
        XCTAssertEqual(names(s), ["D", "A", "B", "C2"])
    }

    func testDeleteLeavesTheOrder() async {
        let backend = MemoryCollectionsBackend()
        let s = await three(backend)
        await s.reorder(s.mine.reversed().map(\.ref))
        let b = s.mine[1].ref
        await s.delete(b)
        XCTAssertEqual(names(s), ["A", "C"])
        XCTAssertFalse(backend.order.contains(b))
        XCTAssertNil(s.card(b))
        let next = store(backend)
        await next.load()
        XCTAssertEqual(names(next), ["A", "C"])
    }

    func testRenameTrimsCapsAndIgnoresBlank() async {
        let backend = MemoryCollectionsBackend()
        let s = store(backend)
        await s.load()
        let made = await s.create(name: "  Films  ")
        XCTAssertEqual(made?.name, "Films")
        let ref = made!.ref
        await s.rename(ref, to: "   ")
        XCTAssertEqual(s.card(ref)?.name, "Films")
        await s.rename(ref, to: String(repeating: "x", count: 120))
        XCTAssertEqual(s.card(ref)?.name.count, PhoneCollectionsStore.maxName)
        XCTAssertEqual(backend.stored.first?.name.count, PhoneCollectionsStore.maxName)
    }

    func testItemDragIsSaved() async {
        let backend = MemoryCollectionsBackend()
        let s = store(backend)
        await s.load()
        let ref = await s.create(name: "Films")!.ref
        for id in ["t1", "t2", "t3", "t4"] { _ = await s.add(meta(id), to: ref) }
        // Drag the last title to the front, then the new second one to the end.
        await s.moveItems(in: ref, fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(s.card(ref)?.items.map(\.id), ["t4", "t1", "t2", "t3"])
        await s.moveItems(in: ref, fromOffsets: IndexSet(integer: 1), toOffset: 4)
        XCTAssertEqual(s.card(ref)?.items.map(\.id), ["t4", "t2", "t3", "t1"])
        XCTAssertEqual(backend.stored.first?.items.map(\.id), ["t4", "t2", "t3", "t1"])
        let next = store(backend)
        await next.load()
        XCTAssertEqual(next.card(ref)?.items.map(\.id), ["t4", "t2", "t3", "t1"])
    }

    func testRemoveTitlesInEditMode() async {
        let backend = MemoryCollectionsBackend()
        let s = store(backend)
        await s.load()
        let ref = await s.create(name: "Films")!.ref
        for id in ["t1", "t2", "t3"] { _ = await s.add(meta(id), to: ref) }
        await s.removeItems(atOffsets: IndexSet([0, 2]), from: ref)
        XCTAssertEqual(s.card(ref)?.items.map(\.id), ["t2"])
        XCTAssertEqual(s.card(ref)?.count, 1)
        XCTAssertEqual(backend.stored.first?.items.map(\.id), ["t2"])
    }

    func testToggleAddsThenRemoves() async {
        let backend = MemoryCollectionsBackend()
        let s = store(backend)
        await s.load()
        let ref = await s.create(name: "Shows")!.ref
        let show = meta("tt9", "series")
        XCTAssertFalse(s.contains(show.id, in: ref))
        let added = await s.toggle(show, in: ref)
        XCTAssertTrue(added)
        XCTAssertTrue(s.contains(show.id, in: ref))
        XCTAssertEqual(backend.stored.first?.items.map(\.id), ["tt9"])
        let still = await s.toggle(show, in: ref)
        XCTAssertFalse(still)
        XCTAssertFalse(s.contains(show.id, in: ref))
        XCTAssertEqual(backend.stored.first?.items.count, 0)
    }

    func testOnlyFilmsAndShowsAreCollectable() {
        XCTAssertTrue(PhoneCollectionsStore.collectable(meta("a", "movie")))
        XCTAssertTrue(PhoneCollectionsStore.collectable(meta("b", "series")))
        XCTAssertFalse(PhoneCollectionsStore.collectable(meta("c", "tv")))
        XCTAssertFalse(PhoneCollectionsStore.collectable(meta("d", "collection")))
    }

    func testTheCapsHold() async {
        let backend = MemoryCollectionsBackend()
        backend.maxCollections = 2
        backend.maxItems = 2
        let s = store(backend)
        await s.load()
        let ref = await s.create(name: "One")!.ref
        await s.create(name: "Two")
        XCTAssertFalse(s.canCreate)
        let third = await s.create(name: "Three")
        XCTAssertNil(third)
        XCTAssertEqual(backend.stored.count, 2)
        _ = await s.add(meta("t1"), to: ref)
        _ = await s.add(meta("t2"), to: ref)
        let full = await s.add(meta("t3"), to: ref)
        XCTAssertFalse(full)
        XCTAssertEqual(s.card(ref)?.items.map(\.id), ["t1", "t2"])
    }

    func testARefusedChangeIsUndone() async {
        let backend = MemoryCollectionsBackend()
        let s = await three(backend)
        let a = s.mine[2].ref
        backend.failNext = true
        await s.rename(a, to: "Nope")
        XCTAssertEqual(s.card(a)?.name, "A")
        backend.failNext = true
        await s.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(names(s), ["C", "B", "A"])
        XCTAssertEqual(backend.order, [])
        backend.failNext = true
        await s.delete(a)
        XCTAssertEqual(names(s), ["C", "B", "A"])
    }

    func testCollectionDeletedElsewhereIsDropped() async {
        let backend = MemoryCollectionsBackend()
        let s = await three(backend)
        let b = s.mine[1].ref
        // The TV deleted B; the phone's next edit of it finds it gone and reads the list again.
        backend.stored.removeAll { $0.id == b }
        await s.rename(b, to: "B2")
        XCTAssertNil(s.card(b))
        XCTAssertEqual(names(s), ["C", "A"])
    }
}
