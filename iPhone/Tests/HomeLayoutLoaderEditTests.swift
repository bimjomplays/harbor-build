import XCTest
@testable import HarborPhone

/// A CountingBrowseSource whose page reads wait while it is held, so a test can edit the layout
/// while a pass is still reading (the editor's all-sources pass is slow on a real engine).
final class GatedBrowseSource: BrowseSource, @unchecked Sendable {
    let inner: CountingBrowseSource

    private let lock = NSLock()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ inner: CountingBrowseSource) { self.inner = inner }

    /// Page reads from now on wait for `release`.
    func hold() { lock.withLock { held = true } }

    func release() {
        let parked: [CheckedContinuation<Void, Never>] = lock.withLock {
            held = false
            let parked = waiting
            waiting = []
            return parked
        }
        for continuation in parked { continuation.resume() }
    }

    /// Page reads waiting for `release`.
    var parkedCount: Int { lock.withLock { waiting.count } }

    private func gate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go: Bool = lock.withLock {
                guard held else { return true }
                waiting.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    func page(for room: Room) async throws -> BrowsePage {
        await gate()
        return try await inner.page(for: room)
    }

    func rows(for room: Room) async throws -> [BrowseRow] { try await page(for: room).rows }

    func continueWatching(for room: Room) async throws -> [ContinueItem] { try await inner.continueWatching(for: room) }
}

/// Edits made while a pass is reading are kept when the pass lands.
@MainActor
final class HomeLayoutLoaderEditTests: XCTestCase {
    private func gated() -> GatedBrowseSource {
        let s = CountingBrowseSource()
        s.pages[.home] = BrowsePage(rows: [
            BrowseRow(key: "trending", title: "Trending", metas: [Meta(id: "a", type: "movie", name: "A")], shape: .poster),
        ], hero: [])
        s.pages[.movies] = BrowsePage(rows: [
            BrowseRow(key: "theaters", title: "In Theaters", metas: [Meta(id: "m1", type: "movie", name: "M1")], shape: .poster),
        ], hero: [])
        s.resuming[.home] = [ContinueItem(id: "cw1", type: "movie", name: "cw1", poster: nil, background: nil, logo: nil,
                                          season: nil, episode: nil, progress: 0.5, lastWatched: nil)]
        return GatedBrowseSource(s)
    }

    private func loader(_ source: GatedBrowseSource, store: HomeLayoutStore) -> HomeLayoutLoader {
        HomeLayoutLoader(HomeLayoutLoader.Dependencies(
            source: source, extras: CountingExtras(), store: store, profileId: "p1",
            classicHome: { false }, hiddenRooms: { [] }, refreshMarks: { _ in },
            listensToEngine: false))
    }

    private func content(_ loader: HomeLayoutLoader, file: StaticString = #filePath, line: UInt = #line) -> HomeContent {
        guard case .loaded(let content) = loader.phase else {
            XCTFail("not loaded: \(loader.phase)", file: file, line: line)
            return HomeContent()
        }
        return content
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<300 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A reorder (it needs nothing new, so it is re-assembled at once) while a quiet pass reads: the
    /// pass lands with the reordered layout, in the loader and on screen.
    func testAnEditDuringAPassThatNeedsNothingNewIsKept() async {
        let s = gated()
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        let l = loader(s, store: store)
        await l.load(quiet: false)
        XCTAssertEqual(content(l).items.first?.id, HomeLayout.defaultContinueWatchingId)

        s.hold()
        let pass = Task { await l.load(quiet: true) }
        await settle { s.parkedCount > 0 }
        XCTAssertGreaterThan(s.parkedCount, 0, "the pass never started reading")

        l.edit { _ = $0.move(id: HomeLayout.defaultContinueWatchingId, by: 1) }
        XCTAssertEqual(l.layout.rows.last?.id, HomeLayout.defaultContinueWatchingId)
        XCTAssertEqual(content(l).items.last?.id, HomeLayout.defaultContinueWatchingId, "the edit was not drawn at once")

        s.release()
        await pass.value

        XCTAssertEqual(l.layout, store.layout(for: "p1"))
        XCTAssertEqual(l.layout.rows.last?.id, HomeLayout.defaultContinueWatchingId, "the pass put the old order back")
        XCTAssertEqual(content(l).items.last?.id, HomeLayout.defaultContinueWatchingId, "Home drew the old order")
    }

    /// A row from a page the pass is not reading, added while it reads: it stays in the layout and is
    /// drawn once its page has been read.
    func testARowAddedDuringAPassIsReadAndKept() async {
        let s = gated()
        let store = HomeLayoutStore(storage: MemoryHomeLayoutStorage())
        let l = loader(s, store: store)
        await l.load(quiet: false)

        s.hold()
        let pass = Task { await l.load(quiet: true) }
        await settle { s.parkedCount > 0 }

        l.edit { _ = $0.insert(.engineRow(room: .movies, key: "theaters"), savedTitle: "In Theaters") }
        XCTAssertEqual(l.layout.rows.count, 3)

        s.release()
        await pass.value
        await settle {
            if case .loaded(let c) = l.phase { return c.rows.contains { $0.key == "theaters" } }
            return false
        }

        XCTAssertEqual(l.layout, store.layout(for: "p1"))
        XCTAssertEqual(l.layout.rows.count, 3, "the added row was dropped")
        XCTAssertTrue(content(l).rows.contains { $0.key == "theaters" }, "the added row was never drawn")
        XCTAssertGreaterThan(s.inner.pageCount(.movies), 0)
    }
}
