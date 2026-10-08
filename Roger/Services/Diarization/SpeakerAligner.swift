import Foundation
import FluidAudio

/// Bridges Parakeet ASR token timings and FluidAudio diarization segments into
/// Roger's speaker-attributed model.
///
/// FluidAudio has no `addSpeakerInfo` convenience (the one SpeakerKit provided),
/// so we do the alignment ourselves: both the ASR token timings and the
/// diarization segments live on the same 16 kHz audio clock, so each word is
/// assigned to the diarization segment covering its time midpoint, speaker
/// changes are moved to nearby sentence ends or pauses, and consecutive
/// same-speaker words are grouped into segments.
enum SpeakerAligner {

    /// Groups tokens into timed text runs split on silence gaps. Used for the
    /// non-diarized mic track (everything is one speaker downstream).
    static func segment(tokens: [TokenTiming], gapThreshold: Double = 0.8) -> [TranscriptTextSegment] {
        runs(of: tokens, gapThreshold: gapThreshold).compactMap { run in
            let text = text(from: run)
            guard !text.isEmpty, let first = run.first, let last = run.last else { return nil }
            return TranscriptTextSegment(startTime: first.startTime, endTime: last.endTime, text: text)
        }
    }

    /// Assigns speakers to whole words, then moves each speaker change to a
    /// natural break nearby.
    ///
    /// Diarization boundaries are only accurate to a few hundred
    /// milliseconds, and Parakeet's tokens are word pieces with their own
    /// timings. Assigning per token split words between speakers ("author" |
    /// "ization") and handed a trailing "." to the next speaker. Here each
    /// word (with its punctuation) gets the speaker covering its midpoint, and
    /// a change is then shifted, within `snapWindow` seconds, to the word gap
    /// that best looks like a turn: after a sentence end, then the longest
    /// pause.
    static func align(
        tokens: [TokenTiming],
        diarization: [TimedSpeakerSegment],
        snapWindow: Double = 2.0
    ) -> [SpeakerSegment] {
        let words = words(from: tokens)
        guard !words.isEmpty else { return [] }
        let sorted = diarization.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        // Raw speaker per word. A word in a gap between diarization segments
        // keeps the running speaker (then the first cluster).
        var speakers: [String] = []
        speakers.reserveCapacity(words.count)
        for word in words {
            let mid = (word.start + word.end) / 2
            let speaker = speaker(at: mid, in: sorted) ?? speakers.last ?? sorted.first?.speakerId ?? "S1"
            speakers.append(speaker)
        }

        absorbBlips(in: &speakers, words: words)

        // Indices where the speaker changes, each snapped to the best break
        // between its neighbours.
        var changes = (1..<words.count).filter { speakers[$0] != speakers[$0 - 1] }
        for k in changes.indices {
            let index = changes[k]
            let lower = k > 0 ? changes[k - 1] + 1 : 1
            let upper = k + 1 < changes.count ? changes[k + 1] - 1 : words.count - 1
            guard lower <= upper else { continue }
            let anchor = words[index].start
            var best = index
            var bestScore = -Double.infinity
            for candidate in lower...upper where abs(words[candidate].start - anchor) <= snapWindow {
                let score = breakScore(before: words[candidate - 1], after: words[candidate])
                    - abs(words[candidate].start - anchor) * 0.1
                if score > bestScore {
                    bestScore = score
                    best = candidate
                }
            }
            changes[k] = best
        }

        // Rebuild runs: each change hands the following words to the speaker
        // the diarizer gave the original change point.
        var result: [SpeakerSegment] = []
        var runStart = 0
        var runSpeaker = speakers[0]
        let originalChanges = (1..<words.count).filter { speakers[$0] != speakers[$0 - 1] }
        for (k, change) in changes.enumerated() {
            appendRun(words[runStart..<change], speaker: runSpeaker, to: &result)
            runStart = change
            runSpeaker = speakers[originalChanges[k]]
        }
        appendRun(words[runStart..<words.count], speaker: runSpeaker, to: &result)
        return mergeShortTurns(result)
    }

    /// Snapping can leave a turn of a word or two between two others, for
    /// example "built out" in the middle of a sentence. Such turns join the
    /// turn before them; same-speaker neighbours then merge.
    private static func mergeShortTurns(_ turns: [SpeakerSegment], maxWords: Int = 3, maxDuration: Double = 1.5) -> [SpeakerSegment] {
        var result: [SpeakerSegment] = []
        for turn in turns {
            let isShort = turn.text.split(separator: " ").count <= maxWords && turn.endTime - turn.startTime < maxDuration
            if let previous = result.last, isShort || previous.speakerId == turn.speakerId {
                result[result.count - 1] = SpeakerSegment(
                    speakerId: previous.speakerId,
                    startTime: previous.startTime,
                    endTime: turn.endTime,
                    text: previous.text + " " + turn.text
                )
            } else {
                result.append(turn)
            }
        }
        return result
    }

    /// Diarization sometimes flips to another speaker for a word or two in
    /// the middle of a sentence. Runs of at most `maxWords` words spanning
    /// under `maxDuration` seconds go to the speaker before them (or after
    /// them, at the very start).
    private static func absorbBlips(
        in speakers: inout [String],
        words: [Word],
        maxWords: Int = 3,
        maxDuration: Double = 1.0
    ) {
        var start = 0
        while start < speakers.count {
            var end = start
            while end + 1 < speakers.count, speakers[end + 1] == speakers[start] { end += 1 }
            let isShort = end - start + 1 <= maxWords && words[end].end - words[start].start < maxDuration
            let neighbour = start > 0 ? speakers[start - 1] : (end + 1 < speakers.count ? speakers[end + 1] : nil)
            if isShort, let neighbour, neighbour != speakers[start] {
                for i in start...end { speakers[i] = neighbour }
                // Re-scan from the merged run's start so chained blips settle.
                start = start > 0 ? max(0, start - 1) : 0
                while start > 0, speakers[start - 1] == speakers[start] { start -= 1 }
                continue
            }
            start = end + 1
        }
    }

    /// One spoken word: its tokens joined, punctuation pieces included.
    struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    /// Groups SentencePiece tokens into words. A piece that starts with a
    /// space (FluidAudio's token timings) or the raw word-boundary marker
    /// starts a new word; anything else (word continuations and punctuation)
    /// joins the current word.
    static func words(from tokens: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        for token in tokens {
            let startsWord = token.token.hasPrefix(" ")
                || token.token.hasPrefix(ASRConstants.sentencePieceWordBoundary)
            if startsWord || words.isEmpty {
                words.append(Word(text: token.token, start: token.startTime, end: token.endTime))
            } else {
                words[words.count - 1].text += token.token
                words[words.count - 1].end = token.endTime
            }
        }
        return words
    }

    /// How much the gap between two words looks like a speaker turn.
    private static func breakScore(before: Word, after: Word) -> Double {
        let gap = max(0, after.start - before.end)
        let trimmed = before.text.trimmingCharacters(in: .whitespaces)
        let sentenceEnd = trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        return min(gap, 2) + (sentenceEnd ? 1 : 0)
    }

    private static func appendRun(_ run: ArraySlice<Word>, speaker: String, to result: inout [SpeakerSegment]) {
        guard let first = run.first, let last = run.last else { return }
        let text = detokenize(run.map(\.text).joined())
        guard !text.isEmpty else { return }
        if let previous = result.last, previous.speakerId == speaker {
            result[result.count - 1] = SpeakerSegment(
                speakerId: speaker,
                startTime: previous.startTime,
                endTime: last.end,
                text: previous.text + " " + text
            )
        } else {
            result.append(SpeakerSegment(speakerId: speaker, startTime: first.start, endTime: last.end, text: text))
        }
    }

    // MARK: - Helpers

    private static func runs(of tokens: [TokenTiming], gapThreshold: Double) -> [[TokenTiming]] {
        var runs: [[TokenTiming]] = []
        var current: [TokenTiming] = []
        for token in tokens {
            if let last = current.last, token.startTime - last.endTime > gapThreshold {
                runs.append(current)
                current = []
            }
            current.append(token)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func speaker(at time: Double, in sorted: [TimedSpeakerSegment]) -> String? {
        for seg in sorted where Double(seg.startTimeSeconds) <= time && time < Double(seg.endTimeSeconds) {
            return seg.speakerId
        }
        // Nearest segment by edge distance when no segment contains the time.
        var best: (id: String, dist: Double)?
        for seg in sorted {
            let dist = time < Double(seg.startTimeSeconds)
                ? Double(seg.startTimeSeconds) - time
                : time - Double(seg.endTimeSeconds)
            if best == nil || dist < best!.dist { best = (seg.speakerId, dist) }
        }
        return best?.id
    }

    /// Detokenizes Parakeet's SentencePiece subword tokens into readable text.
    private static func text(from tokens: [TokenTiming]) -> String {
        detokenize(tokens.map(\.token).joined())
    }

    private static func detokenize(_ joined: String) -> String {
        joined
            .replacingOccurrences(of: ASRConstants.sentencePieceWordBoundary, with: " ")
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
