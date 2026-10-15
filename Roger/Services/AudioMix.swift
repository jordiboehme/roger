import Foundation

/// Mixes the mic and system tracks of a log into one track for the kept
/// `.m4a`. Transcription never uses the mix.
enum AudioMix {
    /// Sample-wise sum, clipped to -1...1. The shorter track is padded with silence.
    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        let count = max(a.count, b.count)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let sum = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
            out[i] = min(1, max(-1, sum))
        }
        return out
    }
}

extension AudioMix {
    /// Offsets at or above this are not trusted as a start delay (a clock
    /// jump or a stale date); the tracks are then left as they are.
    static let maxStartOffset: TimeInterval = 2

    /// Lines up two tracks that started at different moments: the track that
    /// started later gets `offset` seconds of silence at the front, so both
    /// count from the earlier start. `offset` is `bStart - aStart`.
    static func alignStarts(
        _ a: [Float], _ b: [Float], offset: TimeInterval, sampleRate: Double = 16_000
    ) -> (a: [Float], b: [Float]) {
        guard offset != 0, abs(offset) < maxStartOffset else { return (a, b) }
        let padding = [Float](repeating: 0, count: Int((abs(offset) * sampleRate).rounded()))
        return offset > 0 ? (a, padding + b) : (padding + a, b)
    }

    /// `alignStarts` from the two start dates. Unchanged when either is unknown.
    static func alignStarts(
        _ a: [Float], startedAt aStart: Date?, _ b: [Float], startedAt bStart: Date?, sampleRate: Double = 16_000
    ) -> (a: [Float], b: [Float]) {
        guard let aStart, let bStart else { return (a, b) }
        return alignStarts(a, b, offset: bStart.timeIntervalSince(aStart), sampleRate: sampleRate)
    }

    /// The two tracks of a log, lined up to the recording start (the mic
    /// start). `mic` is nil when the mic gave nothing and stays nil, but the
    /// system track is still padded by its delay, so paragraph times count
    /// from the recording start.
    static func alignLogTracks(
        mic: [Float]?, micStartedAt: Date?, system: [Float], systemStartedAt: Date?, sampleRate: Double = 16_000
    ) -> (mic: [Float]?, system: [Float]) {
        let aligned = alignStarts(mic ?? [], startedAt: micStartedAt, system, startedAt: systemStartedAt, sampleRate: sampleRate)
        return (mic == nil ? nil : aligned.a, aligned.b)
    }
}
