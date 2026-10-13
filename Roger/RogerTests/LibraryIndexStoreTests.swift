import Foundation
import Testing
@testable import Roger

@MainActor
struct LibraryIndexStoreTests {
    private func store() -> LibraryIndexStore {
        LibraryIndexStore(externalFiles: { [] }, externalListURL: nil, watchesFileSystem: false)
    }

    private func scope(_ root: String, extras: [String] = []) -> LibraryScanScope {
        LibraryScanScope(
            layout: LibraryLayout(root: URL(fileURLWithPath: root, isDirectory: true)),
            extraFolders: extras.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    @Test func sameScopeKeepsTheIndex() {
        let store = store()
        let a = store.index(for: scope("/RogerFixtures/A"))
        let b = store.index(for: scope("/RogerFixtures/A"))
        #expect(a === b)
    }

    @Test func newRootGivesANewIndex() {
        let store = store()
        let a = store.index(for: scope("/RogerFixtures/A"))
        let b = store.index(for: scope("/RogerFixtures/B"))
        #expect(a !== b)
        #expect(store.current === b)
        #expect(b.scope == scope("/RogerFixtures/B"))
    }

    @Test func newExtraFolderGivesANewIndex() {
        let store = store()
        let a = store.index(for: scope("/RogerFixtures/A"))
        let b = store.index(for: scope("/RogerFixtures/A", extras: ["/RogerFixtures/Old"]))
        #expect(a !== b)
    }

    @Test func scopeChangeStopsTheOldIndex() async {
        let store = store()
        let a = store.index(for: scope("/RogerFixtures/A"))
        #expect(await a.watchingStopped == false)
        _ = store.index(for: scope("/RogerFixtures/B"))
        // The store stops the old index in a task; wait for it without FSEvents timing.
        var stopped = false
        for _ in 0..<100 where !stopped {
            stopped = await a.watchingStopped
            if !stopped { await Task.yield() }
        }
        #expect(stopped)
    }
}
