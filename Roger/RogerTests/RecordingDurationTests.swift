import Foundation
import Testing
@testable import Roger

struct RecordingDurationTests {
    @Test func nothingStoredGetsTheNewDefault() {
        let result = RecordingDurationMigration.migrated(stored: nil, migrated: false)
        #expect(result.value == 300)
        #expect(result.migrated)
    }

    @Test func theOldDefaultBecomesTheNewOne() {
        let result = RecordingDurationMigration.migrated(stored: 120, migrated: false)
        #expect(result.value == 300)
        #expect(result.migrated)
    }

    @Test func a120ThatWasPickedAfterTheMigrationStays() {
        let result = RecordingDurationMigration.migrated(stored: 120, migrated: true)
        #expect(result.value == 120)
        #expect(result.migrated)
    }

    @Test func anotherStoredValueStays() {
        let result = RecordingDurationMigration.migrated(stored: 90, migrated: false)
        #expect(result.value == 90)
        #expect(result.migrated)
    }
}
