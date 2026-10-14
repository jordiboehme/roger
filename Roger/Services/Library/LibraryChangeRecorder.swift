import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryChanges")

/// Where the recorder writes and what a catch-up scans.
struct LibraryChangeEnvironment: Sendable {
    let layout: LibraryLayout
    let extraFolders: [URL]
    let externalRegistry: ExternalTranscriptRegistry
}

/// The app's side of the change log (`<root>/.roger/changes.jsonl`).
/// Calls come from the main actor and run one after the other off the main
/// actor, in call order. After the first operation on a root (at launch,
/// after the library folder changed) that root is caught up: every item
/// that is not in its log yet gets `created`. A failed write is logged as a
/// warning; the next catch-up adds the item.
@MainActor
final class LibraryChangeRecorder {
    /// Nil until the coordinator sets it. Calls before that do nothing.
    var environment: (@MainActor () -> LibraryChangeEnvironment)?
    private var tail: Task<Void, Never>?
    private var logs: [String: ChangeLog] = [:]
    private var caughtUpRoot: String?

    init(environment: (@MainActor () -> LibraryChangeEnvironment)? = nil) {
        self.environment = environment
    }

    /// The item's Markdown is on disk (new, edited, renamed or rewritten).
    func recordWritten(markdownURL: URL, kind: LibraryItemKind) {
        guard let env = environment?() else { return }
        let subject = ChangeKey.subject(markdownURL: markdownURL, kind: kind, root: env.layout.root)
        enqueue(env) { log in
            try await log.record(.written, subject)
        }
    }

    /// These items went to the Trash.
    func recordDeleted(_ items: [LibraryItem]) {
        guard let env = environment?(), !items.isEmpty else { return }
        let subjects = items.compactMap { ChangeKey.subject(for: $0, root: env.layout.root) }
        enqueue(env) { log in
            for subject in subjects {
                try await log.record(.deleted, subject)
            }
        }
    }

    /// Catches up the current root now. Called at launch and when the
    /// library folder changes.
    func reconcile() {
        guard let env = environment?() else { return }
        caughtUpRoot = nil
        enqueue(env) { _ in }
    }

    /// Waits until every queued operation ran. For tests.
    func waitUntilIdle() async {
        await tail?.value
    }

    private func enqueue(_ env: LibraryChangeEnvironment, _ operation: @escaping @Sendable (ChangeLog) async throws -> Void) {
        let rootKey = env.layout.root.standardizedFileURL.path
        let log = logs[rootKey] ?? ChangeLog(root: env.layout.root)
        logs[rootKey] = log
        let needsCatchUp = caughtUpRoot != rootKey
        caughtUpRoot = rootKey
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            // The operation first: an item written a moment ago is then
            // `created` by its own record, not by the catch-up (which would
            // make the record an `updated`).
            do {
                try await operation(log)
            } catch {
                logger.warning("Change log not updated: \(error.localizedDescription, privacy: .public)")
            }
            guard needsCatchUp else { return }
            do {
                let items = LibraryScanner.scanAll(
                    scope: LibraryScanScope(layout: env.layout, extraFolders: env.extraFolders),
                    externalFiles: env.externalRegistry.listedFiles()
                )
                let added = try await log.reconcile(items: items).count
                logger.notice("Change log caught up, \(added) items added")
            } catch {
                logger.warning("Change log not caught up: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
