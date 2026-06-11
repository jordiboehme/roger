import Foundation
import FluidAudio

/// Bridges Parakeet ASR token timings and FluidAudio diarization segments into
/// Roger's speaker-attributed model.
///
/// FluidAudio has no `addSpeakerInfo` convenience (the one SpeakerKit provided),
/// so we do the alignment ourselves: both the ASR token timings and the
/// diarization segments live on the same 16 kHz audio clock, so each token is
/// assigned to the diarization segment covering its time midpoint, then
/// consecutive same-speaker tokens are grouped into segments.
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

    /// Assigns each token to the diarization segment covering its midpoint, then
    /// groups consecutive same-speaker tokens into `SpeakerSegment`s.
    static func align(tokens: [TokenTiming], diarization: [TimedSpeakerSegment]) -> [SpeakerSegment] {
        guard !tokens.isEmpty else { return [] }
        let sorted = diarization.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        var result: [SpeakerSegment] = []
        var speakerOf: String? = nil
        var bucket: [TokenTiming] = []

        func flush() {
            guard let speaker = speakerOf, !bucket.isEmpty else { bucket = []; return }
            let text = text(from: bucket)
            if !text.isEmpty, let first = bucket.first, let last = bucket.last {
                result.append(SpeakerSegment(
                    speakerId: speaker,
                    startTime: first.startTime,
                    endTime: last.endTime,
                    text: text
                ))
            }
            bucket = []
        }

        for token in tokens {
            let mid = (token.startTime + token.endTime) / 2
            // Fall back to the running speaker (then the first cluster) when a
            // token lands in a gap between diarization segments.
            let speaker = speaker(at: mid, in: sorted) ?? speakerOf ?? sorted.first?.speakerId ?? "S1"
            if speaker != speakerOf {
                flush()
                speakerOf = speaker
            }
            bucket.append(token)
        }
        flush()
        return result
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
        tokens.map(\.token).joined()
            .replacingOccurrences(of: ASRConstants.sentencePieceWordBoundary, with: " ")
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
