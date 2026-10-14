import Foundation
import Testing
@testable import Roger

struct LibraryIndexTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    @discardableResult
    private func writeLog(_ layout: LibraryLayout, at date: Date, text: String) throws -> URL {
        let folder = layout.monthFolder(.logs, for: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(LogEntryWriter.baseName(for: date) + ".md")
        let entry = LogEntry(text: text, startedAt: date, endedAt: date.addingTimeInterval(10), presetName: "Log", language: nil)
        try LogEntryWriter.content(for: entry, audioFileName: nil, generatedAt: date).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func writeMeeting(in parent: URL, name: String, text: String) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try MeetingTranscriptWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: text)],
            metadata: .init(
                session: MeetingSession(id: UUID(), folder: folder, startedAt: date),
                durationSeconds: 60, speakerCount: 1, language: nil,
                micPresent: false, systemPresent: false, audioKept: true,
                diarized: false, diarizationFailed: false
            )
        )
        return folder
    }

    private func writeTranscript(_ url: URL, title: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fm = TranscriptFrontmatter(
            title: title, description: "x", tags: ["transcript"],
            sourceDate: date, temporalConfidence: .explicit, status: "stable"
        )
        try (fm.render() + "# \(title)\n\nSome words\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeIndex(
        _ layout: LibraryLayout,
        extras: [URL] = [],
        external: @escaping @Sendable () -> [URL] = { [] },
        listURL: URL? = nil
    ) -> InMemoryLibraryIndex {
        InMemoryLibraryIndex(
            scope: LibraryScanScope(layout: layout, extraFolders: extras),
            externalFiles: external,
            externalListURL: listURL
        )
    }

    @Test func findsEveryKindAndPlace() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        try writeLog(layout, at: date, text: "Called the supplier")
        try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "2026-09-21 09-00", text: "Hello")
        try writeTranscript(layout.monthFolder(.transcripts, for: date).appendingPathComponent("talk.mp4.md"), title: "talk")
        let old = base.appendingPathComponent("Roger Recordings", isDirectory: true)
        try writeMeeting(in: old, name: "2026-01-01 10-00", text: "Old meeting")
        try writeTranscript(old.appendingPathComponent("legacy.mp3.md"), title: "legacy")
        let outside = base.appendingPathComponent("Elsewhere/podcast.m4a.md")
        try writeTranscript(outside, title: "podcast")

        let index = makeIndex(layout, extras: [old], external: { [outside] })
        let items = await index.items()
        #expect(items.filter { $0.kind == .log }.count == 1)
        #expect(items.filter { $0.kind == .meeting }.count == 2)
        #expect(items.filter { $0.kind == .transcript }.count == 3)
        #expect(await index.search(LibraryQuery(kind: .meeting)).count == 2)
        #expect(await index.search(LibraryQuery(searchText: "supplier")).map(\.kind) == [.log])
    }

    @Test func retryLeftoversAreNotItems() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let session = try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "s", text: "First run")
        // A retry moves the old transcript aside to transcript.previous.md.
        try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "s", text: "Second run")
        let segment = try #require(try MeetingSegmentWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: "Part")],
            sessionStartedAt: date, chunkStart: date, chunkEnd: date.addingTimeInterval(30),
            folder: session, provisional: false
        ))
        try FileManager.default.copyItem(at: segment, to: session.appendingPathComponent("2020-01-01 00-00-00.previous.md"))
        #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.previous.md").path))

        let items = await makeIndex(layout).items()
        #expect(items.count == 1)
        #expect(items.first?.url.lastPathComponent == "transcript.md")
        #expect(items.first?.firstLine == "Second run")
    }

    @Test func symlinkedSpellingsAreOneItem() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let layout = LibraryLayout(root: real)
        let url = try writeLog(layout, at: date, text: "One")
        let viaLink = link.appendingPathComponent(url.path.replacingOccurrences(of: real.path + "/", with: ""))
        #expect(FileManager.default.fileExists(atPath: viaLink.path))
        #expect(viaLink.path != url.path)
        #expect(LibraryPath.canonical(viaLink) == LibraryPath.canonical(url))

        let index = makeIndex(layout)
        let items = await index.items()
        #expect(items.map(\.id) == [LibraryPath.canonical(url)])
        await index.apply(changedPaths: [viaLink.path, url.path])
        #expect(await index.items().count == 1)

        // FSEvents spells temp paths /private/var/...; this holds on every Mac.
        let varSpelling = URL(fileURLWithPath: "/var/folders")
        #expect(LibraryPath.canonical(varSpelling) == "/private/var/folders")

        let missing = base.appendingPathComponent("not/there.md")
        #expect(LibraryPath.canonical(missing) == LibraryPath.canonical(base) + "/not/there.md")
    }

    @Test func applyPicksUpNewMonthFolder() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        try writeLog(layout, at: date, text: "First")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)

        let later = date.addingTimeInterval(40 * 86_400)
        let next = try writeLog(layout, at: later, text: "Next month")
        await index.apply(changedPaths: [next.deletingLastPathComponent().path])
        #expect(await index.items().count == 2)
    }

    @Test func applyRemovesADeletedFile() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let url = try writeLog(layout, at: date, text: "Gone soon")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        try FileManager.default.removeItem(at: url)
        await index.apply(changedPaths: [url.path])
        #expect(await index.items().isEmpty)
    }

    @Test func applyReplacesUnfinishedMeetingWhenTranscriptAppears() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = layout.monthFolder(.meetings, for: date).appendingPathComponent("2026-09-21 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chunk = folder.appendingPathComponent("mic-001.caf")
        try Data().write(to: chunk)
        let index = makeIndex(layout)
        #expect(await index.items().first?.isUnfinished == true)

        try writeMeeting(in: folder.deletingLastPathComponent(), name: folder.lastPathComponent, text: "Done")
        try FileManager.default.removeItem(at: chunk)
        await index.apply(changedPaths: [folder.appendingPathComponent("transcript.md").path, chunk.path])
        let items = await index.items()
        #expect(items.count == 1)
        #expect(items.first?.isUnfinished == false)
        #expect(items.first?.hasMarkdown == true)
    }

    @Test func applyDropsATrashedSession() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "s", text: "Bye")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        try FileManager.default.removeItem(at: folder)
        await index.apply(changedPaths: [folder.path])
        #expect(await index.items().isEmpty)
    }

    @Test func externalListChangeAddsTheTranscript() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        let registry = ExternalTranscriptRegistry(fileURL: base.appendingPathComponent("Support/external-transcripts.json"))
        let outside = base.appendingPathComponent("Downloads/talk.mp4.md")
        try writeTranscript(outside, title: "talk")
        let index = makeIndex(layout, external: { registry.existingFiles() }, listURL: registry.fileURL)
        #expect(await index.items().isEmpty)

        try registry.add(outside)
        await index.apply(changedPaths: [registry.fileURL.path])
        #expect(await index.items().map(\.title) == ["talk"])
    }

    @Test func changesYieldAfterBuildAndAfterRealChanges() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let index = makeIndex(layout)
        var changes = index.changes.makeAsyncIterator()
        _ = await index.items()
        #expect(await changes.next() != nil)   // the first build

        let url = try writeLog(layout, at: date, text: "New")
        await index.apply(changedPaths: [url.path])
        #expect(await changes.next() != nil)
    }

    @Test func unrelatedPathsAreIgnored() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let index = makeIndex(LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true)))
        #expect(await index.unit(forChangedPath: base.appendingPathComponent("Other/file.md").path) == nil)
        #expect(await index.unit(forChangedPath: base.appendingPathComponent("Roger").path) == .everything)
    }

    @Test func hiddenFilesAreIgnoredButHiddenExtraFoldersAreNot() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        let hiddenExtra = base.appendingPathComponent(".old-meetings", isDirectory: true)
        let index = makeIndex(layout, extras: [hiddenExtra])
        let month = layout.monthFolder(.logs, for: date)
        #expect(await index.unit(forChangedPath: month.appendingPathComponent(".DS_Store").path) == nil)
        #expect(await index.unit(forChangedPath: hiddenExtra.path) == .extraFolder(LibraryPath.canonical(hiddenExtra)))
        #expect(await index.unit(forChangedPath: hiddenExtra.appendingPathComponent(".DS_Store").path) == nil)
    }

    @Test func hiddenPartsBelowKindFoldersAreIgnored() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        let index = makeIndex(layout)
        let month = layout.monthFolder(.logs, for: date)
        #expect(await index.unit(forChangedPath: month.appendingPathComponent(".draft.md").path) == nil)
        #expect(await index.unit(forChangedPath: month.appendingPathComponent(".trash/old.md").path) == nil)
        #expect(await index.unit(forChangedPath: layout.kindFolder(.transcripts).appendingPathComponent(".cache/x.md").path) == nil)
        #expect(await index.unit(forChangedPath: layout.kindFolder(.meetings).appendingPathComponent("2026/.tmp/s/transcript.md").path) == nil)
    }

    /// A log inside a hidden folder (`.trash/`) is skipped by the full scan
    /// and by an update alike.
    @Test func aLogInAHiddenFolderIsNotAddedByAnUpdate() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let visible = try writeLog(layout, at: date, text: "Visible")
        let hidden = visible.deletingLastPathComponent().appendingPathComponent(".trash/old.md")
        try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: visible, to: hidden)
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        await index.apply(changedPaths: [hidden.path])
        #expect(await index.items().map(\.id) == [LibraryPath.canonical(visible)])
    }

    /// A session directly in `Meetings/` (not at `YYYY/MM/`): editing its
    /// transcript updates the item instead of dropping it.
    @Test func aShallowSessionIsUpdatedInPlace() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = try writeMeeting(in: layout.kindFolder(.meetings), name: "2026-09-21 09-00", text: "First")
        let index = makeIndex(layout)
        #expect(await index.items().first?.firstLine == "First")
        try writeMeeting(in: layout.kindFolder(.meetings), name: "2026-09-21 09-00", text: "Second")
        await index.apply(changedPaths: [folder.appendingPathComponent("transcript.md").path])
        let items = await index.items()
        #expect(items.count == 1)
        #expect(items.first?.firstLine == "Second")
    }

    @Test func aNewSessionTwoLevelsDownIsFound() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let index = makeIndex(layout)
        #expect(await index.items().isEmpty)
        let year = layout.kindFolder(.meetings).appendingPathComponent("2026", isDirectory: true)
        let folder = try writeMeeting(in: year, name: "2026-09-21 09-00", text: "Hello")
        await index.apply(changedPaths: [folder.appendingPathComponent("transcript.md").path])
        #expect(await index.items().map(\.folderURL.path) == [LibraryPath.canonical(folder)])
    }

    @Test func aTrashedShallowSessionIsDropped() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = try writeMeeting(in: layout.kindFolder(.meetings), name: "s", text: "Bye")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        try FileManager.default.removeItem(at: folder)
        await index.apply(changedPaths: [folder.path])
        #expect(await index.items().isEmpty)
    }

    /// A root on a drive that is not connected: no parent folder (it could
    /// be all of `~/Documents`) is watched in its place.
    @Test func aMissingRootIsReportedAndNotWatchedThroughItsParent() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let index = makeIndex(LibraryLayout(root: base.appendingPathComponent("Drive/Roger", isDirectory: true)))
        let missing = await index.libraryRootMissing()
        #expect(missing)
        #expect(await index.watchedPaths().isEmpty)
    }

    @Test func recheckFindsARootThatAppeared() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Drive/Roger", isDirectory: true))
        let index = makeIndex(layout)
        #expect(await index.items().isEmpty)
        try writeLog(layout, at: date, text: "Back again")
        await index.recheckRoot()
        let missing = await index.libraryRootMissing()
        #expect(!missing)
        #expect(await index.items().count == 1)
        #expect(await index.watchedPaths() == [LibraryPath.canonical(layout.root)])
    }

    /// After a rename the index reads the file at once, not when the folder
    /// watcher reports it.
    @Test func refreshReadsAFileNow() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let url = try writeLog(layout, at: date, text: "Before")
        let index = makeIndex(layout)
        #expect(await index.items().first?.firstLine == "Before")
        try writeLog(layout, at: date, text: "After")
        await index.refresh(paths: [url.path])
        #expect(await index.items().first?.firstLine == "After")
    }
}
