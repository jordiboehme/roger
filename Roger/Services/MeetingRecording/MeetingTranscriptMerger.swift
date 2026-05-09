import Foundation
import SpeakerKit
import WhisperKit

/// Pure functions that turn the mic transcript and the diarized system
/// transcript into a single ordered paragraph stream. Mic-side dominant
/// speaker → "Me". Every other speaker (additional mic clusters and all
/// system clusters) joins one unified `Other N` pool numbered by
/// first-appearance time across both tracks.
enum MeetingTranscriptMerger {
    struct Paragraph: Sendable, Equatable {
        let speaker: String
        let startTime: Float
        let text: String
    }

    /// Mic-side input. Exactly one of the two cases is used per call.
    enum MicInput {
        /// Mic diarization off (or its fallback): every segment is "Me".
        case flat([TranscriptionSegment])
        /// Mic diarization on: dominant cluster becomes "Me", others pool
        /// into the unified Other N namespace shared with the system track.
        case diarized([[SpeakerSegment]])
        /// No mic capture at all (mic silenced or absent from session).
        case none
    }

    /// `systemSpeakerSegments` is SpeakerKit's `[[SpeakerSegment]]` from the
    /// system m4a, already grouped by `addSpeakerInfo(strategy: .subsegment)`.
    static func merge(
        mic: MicInput,
        systemSpeakerSegments: [[SpeakerSegment]]
    ) -> [Paragraph] {
        // 1. Resolve mic-side: produce labelled (speaker, start, end, text)
        // entries, plus the set of mic cluster IDs that should NOT be in
        // the unified Other N pool because they are "Me".
        var entries: [Entry] = []
        var dominantMicClusterID: Int? = nil

        switch mic {
        case .none:
            break

        case .flat(let segments):
            for seg in segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                entries.append(Entry(
                    sourceKey: SourceKey(track: .mic, clusterID: -1),
                    start: seg.start,
                    end: seg.end,
                    text: text,
                    forcedLabel: "Me"
                ))
            }

        case .diarized(let speakerSegments):
            // Total speech-time per cluster — pick the dominant one as "Me".
            var totalDurationByCluster: [Int: Float] = [:]
            for group in speakerSegments {
                for seg in group {
                    guard let id = seg.speaker.speakerId else { continue }
                    totalDurationByCluster[id, default: 0] += max(0, seg.endTime - seg.startTime)
                }
            }
            dominantMicClusterID = totalDurationByCluster
                .max(by: { $0.value < $1.value })?
                .key

            for group in speakerSegments {
                for seg in group {
                    guard let id = seg.speaker.speakerId else { continue }
                    let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let forced = (id == dominantMicClusterID) ? "Me" : nil
                    entries.append(Entry(
                        sourceKey: SourceKey(track: .mic, clusterID: id),
                        start: seg.startTime,
                        end: seg.endTime,
                        text: text,
                        forcedLabel: forced
                    ))
                }
            }
        }

        // 2. Add system-side entries with track-namespaced source keys.
        for group in systemSpeakerSegments {
            for seg in group {
                guard let id = seg.speaker.speakerId else { continue }
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                entries.append(Entry(
                    sourceKey: SourceKey(track: .system, clusterID: id),
                    start: seg.startTime,
                    end: seg.endTime,
                    text: text,
                    forcedLabel: nil
                ))
            }
        }

        // 3. Build "Other N" labels for every non-"Me" source key, numbered
        // by first appearance across both tracks.
        var firstAppearance: [SourceKey: Float] = [:]
        for entry in entries where entry.forcedLabel == nil {
            if firstAppearance[entry.sourceKey] == nil
                || entry.start < firstAppearance[entry.sourceKey]!
            {
                firstAppearance[entry.sourceKey] = entry.start
            }
        }
        let orderedKeys = firstAppearance
            .sorted { $0.value < $1.value }
            .map { $0.key }
        var otherLabels: [SourceKey: String] = [:]
        for (idx, key) in orderedKeys.enumerated() {
            otherLabels[key] = "Other \(idx + 1)"
        }

        // 4. Resolve final speaker label for each entry.
        let labelled = entries.compactMap { entry -> LabelledEntry? in
            let speaker: String
            if let forced = entry.forcedLabel {
                speaker = forced
            } else if let pooled = otherLabels[entry.sourceKey] {
                speaker = pooled
            } else {
                return nil
            }
            return LabelledEntry(start: entry.start, end: entry.end, text: entry.text, speaker: speaker)
        }
        .sorted { $0.start < $1.start }

        return groupIntoParagraphs(labelled)
    }

    // MARK: - Internals

    private enum Track: Hashable { case mic, system }

    private struct SourceKey: Hashable {
        let track: Track
        let clusterID: Int
    }

    private struct Entry {
        let sourceKey: SourceKey
        let start: Float
        let end: Float
        let text: String
        /// When non-nil the label is fixed (currently only "Me"). Otherwise
        /// the entry is pooled into the unified Other N namespace.
        let forcedLabel: String?
    }

    private struct LabelledEntry {
        let start: Float
        let end: Float
        let text: String
        let speaker: String
    }

    /// Groups consecutive same-speaker entries into paragraphs. Starts a new
    /// paragraph when speaker changes, on a > 1.5 s silence between entries,
    /// or when the running paragraph already exceeds 80 words.
    private static func groupIntoParagraphs(_ entries: [LabelledEntry]) -> [Paragraph] {
        guard !entries.isEmpty else { return [] }
        let gapThreshold: Float = 1.5
        let maxWords = 80

        var paragraphs: [Paragraph] = []
        var currentSpeaker = entries[0].speaker
        var currentStart = entries[0].start
        var currentEnd = entries[0].end
        var currentTexts: [String] = [entries[0].text]
        var currentWordCount = entries[0].text.split(separator: " ").count

        for entry in entries.dropFirst() {
            let speakerChanged = entry.speaker != currentSpeaker
            let bigGap = (entry.start - currentEnd) > gapThreshold
            let tooLong = currentWordCount > maxWords

            if speakerChanged || bigGap || tooLong {
                paragraphs.append(Paragraph(
                    speaker: currentSpeaker,
                    startTime: currentStart,
                    text: collapseWhitespace(currentTexts.joined(separator: " "))
                ))
                currentSpeaker = entry.speaker
                currentStart = entry.start
                currentEnd = entry.end
                currentTexts = [entry.text]
                currentWordCount = entry.text.split(separator: " ").count
            } else {
                currentTexts.append(entry.text)
                currentEnd = entry.end
                currentWordCount += entry.text.split(separator: " ").count
            }
        }
        paragraphs.append(Paragraph(
            speaker: currentSpeaker,
            startTime: currentStart,
            text: collapseWhitespace(currentTexts.joined(separator: " "))
        ))
        return paragraphs
    }

    private static func collapseWhitespace(_ s: String) -> String {
        return s.split { $0.isWhitespace }.joined(separator: " ")
    }
}
