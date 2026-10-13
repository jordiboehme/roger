import Foundation
import Testing
@testable import Roger

struct TranscriptFrontmatterTests {
    @Test func quotesQuotesAndNewlines() {
        #expect(TranscriptFrontmatter.quoted("a \"b\"\nc") == "\"a \\\"b\\\"\\nc\"")
    }

    @Test func dayIsPlainDate() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 13; c.hour = 14; c.minute = 32
        let date = Calendar.current.date(from: c)!
        #expect(TranscriptFrontmatter.day(date) == "2026-10-13")
    }
}
