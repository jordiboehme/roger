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
}
