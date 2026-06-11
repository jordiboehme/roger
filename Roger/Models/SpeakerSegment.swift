import Foundation

/// A contiguous run of speech attributed to one diarization cluster, with the
/// transcribed text for that run.
///
/// Roger-owned replacement for SpeakerKit's `SpeakerSegment`. FluidAudio's
/// diarizer returns time ranges with a String `speakerId` ("S1", "S2", …) and
/// the ASR returns token timings; `SpeakerAligner` joins the two into these.
struct SpeakerSegment: Sendable, Equatable {
    /// Diarization cluster identifier, e.g. "S1". Anonymous — not a real name.
    let speakerId: String
    let startTime: Double
    let endTime: Double
    let text: String
}

/// A timed run of transcribed text with no speaker attribution — used for the
/// mic track when diarization is off (every run becomes "Me" downstream).
struct TranscriptTextSegment: Sendable, Equatable {
    let startTime: Double
    let endTime: Double
    let text: String
}
