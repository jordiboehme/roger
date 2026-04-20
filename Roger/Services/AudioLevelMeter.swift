import Foundation
import Observation

/// Smoothed microphone level in the range 0...1, driven by per-chunk energy
/// from WhisperKit's streaming transcriber. The UI reads `level` each frame
/// to animate the floating waveform.
///
/// Smoothing uses asymmetric EMA — fast attack so a loud syllable snaps the
/// bars up, slow release so the bars don't twitch between WhisperKit's
/// ~10 Hz callbacks.
@MainActor
@Observable
final class AudioLevelMeter {
    private(set) var level: Float = 0

    /// Raw `bufferEnergy` value that maps to a full-height bar.
    var ceiling: Float = 0.25
    /// EMA factor applied when the incoming target is above the current level.
    var attack: Float = 0.85
    /// EMA factor applied when the incoming target is below the current level.
    var release: Float = 0.35

    func ingest(raw: Float) {
        let target = max(0, min(1, raw / ceiling))
        let k = target > level ? attack : release
        level += (target - level) * k
    }

    func reset() {
        level = 0
    }
}
