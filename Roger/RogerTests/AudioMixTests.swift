import Foundation
import Testing
@testable import Roger

struct AudioMixTests {
    @Test func sumsAndPadsTheShorterTrack() {
        #expect(AudioMix.mix([0.1, 0.2, 0.3], [0.1]) == [0.2, 0.2, 0.3])
        #expect(AudioMix.mix([], [0.5, -0.5]) == [0.5, -0.5])
    }

    @Test func clips() {
        #expect(AudioMix.mix([0.8, -0.8], [0.5, -0.5]) == [1.0, -1.0])
    }

    @Test func padsTheLaterTrackAtTheFront() {
        let aligned = AudioMix.alignStarts([1, 1], [2, 2], offset: 0.3, sampleRate: 10)
        #expect(aligned.a == [1, 1])
        #expect(aligned.b == [0, 0, 0, 2, 2])
    }

    @Test func padsTheFirstTrackWhenItStartedLater() {
        let aligned = AudioMix.alignStarts([1], [2], offset: -0.2, sampleRate: 10)
        #expect(aligned.a == [0, 0, 1])
        #expect(aligned.b == [2])
    }

    @Test func leavesTracksAloneForNoOrImplausibleOffsets() {
        for offset in [0, 2, 5, -2] as [TimeInterval] {
            let aligned = AudioMix.alignStarts([1], [2], offset: offset, sampleRate: 10)
            #expect(aligned.a == [1])
            #expect(aligned.b == [2])
        }
    }

    @Test func alignsFromStartDates() {
        let mic = Date(timeIntervalSince1970: 100)
        let aligned = AudioMix.alignStarts([1], startedAt: mic, [2], startedAt: mic.addingTimeInterval(0.1), sampleRate: 10)
        #expect(aligned.b == [0, 2])
        let unknown = AudioMix.alignStarts([1], startedAt: nil, [2], startedAt: mic, sampleRate: 10)
        #expect(unknown.b == [2])
    }

    /// A system-only log: the mic gave nothing but its start date is known.
    @Test func padsTheSystemTrackWhenTheMicIsEmpty() {
        let mic = Date(timeIntervalSince1970: 100)
        let aligned = AudioMix.alignStarts([], startedAt: mic, [2], startedAt: mic.addingTimeInterval(0.2), sampleRate: 10)
        #expect(aligned.a == [])
        #expect(aligned.b == [0, 0, 2])
    }

    @Test func logTracksKeepAMissingMicMissing() {
        let mic = Date(timeIntervalSince1970: 100)
        let later = AudioMix.alignLogTracks(mic: nil, micStartedAt: mic, system: [2], systemStartedAt: mic.addingTimeInterval(0.1), sampleRate: 10)
        #expect(later.mic == nil)
        #expect(later.system == [0, 2])
        // The system track started first: the missing mic gets no silence.
        let earlier = AudioMix.alignLogTracks(mic: nil, micStartedAt: mic, system: [2], systemStartedAt: mic.addingTimeInterval(-0.1), sampleRate: 10)
        #expect(earlier.mic == nil)
        #expect(earlier.system == [2])
        let both = AudioMix.alignLogTracks(mic: [1], micStartedAt: mic, system: [2], systemStartedAt: mic.addingTimeInterval(0.1), sampleRate: 10)
        #expect(both.mic == [1])
        #expect(both.system == [0, 2])
    }
}
