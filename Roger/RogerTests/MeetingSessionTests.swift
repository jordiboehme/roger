import Foundation
import Testing
@testable import Roger

struct MeetingSessionTests {
    @Test func stableIDFollowsTheFolder() {
        let a = URL(fileURLWithPath: "/tmp/Roger/Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        let sameOtherSpelling = URL(fileURLWithPath: "/tmp/Roger/Meetings/2026/../2026/10/2026-10-13 09-00")
        let b = URL(fileURLWithPath: "/tmp/Roger/Meetings/2026/10/2026-10-13 10-00")
        #expect(MeetingSession.stableID(for: a) == MeetingSession.stableID(for: a))
        #expect(MeetingSession.stableID(for: a) == MeetingSession.stableID(for: sameOtherSpelling))
        #expect(MeetingSession.stableID(for: a) != MeetingSession.stableID(for: b))
    }
}
