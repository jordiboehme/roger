import Foundation

struct AgentsConsumerRow: Equatable, Identifiable {
    let name: String
    let seq: Int
    let updatedAt: Date
    /// Events after the bookmark (not grouped by item).
    let openEvents: Int

    var id: String { name }
}

/// What the Agents tab shows about the change log.
struct AgentsLibraryStatus: Equatable {
    let libraryPath: String
    let isSetUp: Bool
    let eventCount: Int
    let lastEventAt: Date?
    let consumers: [AgentsConsumerRow]

    static func read(root: URL) -> AgentsLibraryStatus {
        guard let events = try? ChangeLogFile.readEvents(root: root) else {
            return AgentsLibraryStatus(libraryPath: root.path, isSetUp: false, eventCount: 0, lastEventAt: nil, consumers: [])
        }
        let consumers = ConsumerBookmarks(root: root).all().map { named in
            AgentsConsumerRow(
                name: named.name,
                seq: named.bookmark.seq,
                updatedAt: named.bookmark.updatedAt,
                openEvents: events.filter { $0.seq > named.bookmark.seq }.count
            )
        }
        return AgentsLibraryStatus(
            libraryPath: root.path,
            isSetUp: true,
            eventCount: events.count,
            lastEventAt: events.max { $0.seq < $1.seq }?.at,
            consumers: consumers
        )
    }
}
