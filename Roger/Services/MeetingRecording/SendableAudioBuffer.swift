import AVFoundation

/// Crosses Swift 6 strict-concurrency boundaries with an `AVAudioPCMBuffer`.
/// Apple's class is not declared `Sendable`, but we only ever mutate it from
/// a single owning queue and then hand the reference off to consumers that
/// only read frame data. Marking the wrapper `@unchecked Sendable` is sound
/// for that ownership model and avoids needing actor-hopping noise on every
/// hand-off.
struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
