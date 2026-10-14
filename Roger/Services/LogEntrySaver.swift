import Foundation

/// Saving a log entry after a dictation with a log preset: what is written
/// (text, audio, `sources`) and what is recorded for agents. The
/// coordinator only shows the outcome.
struct LogEntrySaver: Sendable {
    enum Outcome: Equatable, Sendable {
        /// Nothing left after processing. Nothing was written.
        case empty
        /// The entry is on disk and recorded.
        case saved(URL)
        /// The custom library folder is missing (the message names it).
        /// Nothing was written or recorded.
        case libraryMissing(String)
        /// The write failed. Nothing was recorded.
        case failed(String)
    }

    let layout: LibraryLayout
    /// The root that may be created when missing. Tests pass a temp folder.
    var defaultRoot: URL = LibraryLayout.defaultRoot
    var encodeAudio: @Sendable ([Float], URL) throws -> Void = LogAudioEncoder.writeM4A

    /// True when there is nothing to save.
    static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes the entry: the language is the detected one, else the
    /// preset's pin; the recording is kept only when the preset says so
    /// (then `sources` lists it). `recordWritten` runs only after the
    /// file is on disk.
    @MainActor
    func save(
        _ text: String,
        preset: DictationPreset,
        startedAt: Date,
        endedAt: Date,
        detectedLanguage: String?,
        samples: [Float]?,
        recordWritten: @MainActor (URL) -> Void
    ) async -> Outcome {
        guard !Self.isEmpty(text) else { return .empty }
        let entry = LogEntry(
            text: text,
            startedAt: startedAt,
            endedAt: endedAt,
            presetName: preset.name,
            language: detectedLanguage ?? preset.language
        )
        do {
            let url = try await LogEntryWriter.write(
                entry,
                layout: layout,
                audioSamples: preset.keepAudio ? samples : nil,
                defaultRoot: defaultRoot,
                encodeAudio: encodeAudio
            )
            recordWritten(url)
            return .saved(url)
        } catch let missing as LibraryRootMissingError {
            return .libraryMissing(missing.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
