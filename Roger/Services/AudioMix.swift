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
