import Foundation
import Testing
@testable import Roger

struct InputChoiceTests {
    @Test func migratesAPinnedDevice() {
        let list = InputChoice.migrated(selectedUID: "usb-1", nameForUID: { _ in "Webcam" })
        #expect(list == [.device(uid: "usb-1", name: "Webcam"), .systemDefault])
    }

    @Test func migratesAPinnedDeviceThatIsNotConnected() {
        let list = InputChoice.migrated(selectedUID: "gone", nameForUID: { _ in nil })
        #expect(list == [.device(uid: "gone", name: "gone"), .systemDefault])
    }

    @Test func migratesAutomatic() {
        #expect(InputChoice.migrated(selectedUID: nil, nameForUID: { _ in nil }) == [.systemDefault])
    }

    @Test func repairAppendsSystemDefaultAndDropsDuplicates() {
        let a = InputChoice.device(uid: "a", name: "A")
        #expect(InputChoice.repaired([a, a]) == [a, .systemDefault])
        #expect(InputChoice.repaired([.systemDefault, a, .systemDefault]) == [.systemDefault, a])
    }

    @Test func resolvesFirstConnected() {
        let list: [InputChoice] = [.device(uid: "headset", name: "H"), .device(uid: "webcam", name: "W"), .systemDefault]
        #expect(InputChoice.resolve(list, connectedUIDs: ["webcam", "builtin"]) == "webcam")
        #expect(InputChoice.resolve(list, connectedUIDs: ["headset", "webcam"]) == "headset")
        #expect(InputChoice.resolve(list, connectedUIDs: ["builtin"]) == nil)
    }

    @Test func systemDefaultFirstWins() {
        let list: [InputChoice] = [.systemDefault, .device(uid: "webcam", name: "W")]
        #expect(InputChoice.resolve(list, connectedUIDs: ["webcam"]) == nil)
    }

    @Test func roundTrip() throws {
        let list: [InputChoice] = [.device(uid: "a", name: "A"), .systemDefault]
        let back = try JSONDecoder().decode([InputChoice].self, from: JSONEncoder().encode(list))
        #expect(back == list)
    }

    @Test func resolveAsksNothingWhenSystemDefaultComesFirst() {
        let list: [InputChoice] = [.systemDefault, .device(uid: "webcam", name: "W")]
        let uid = InputChoice.resolve(list) { _ in
            Issue.record("Core Audio must not be asked for a list that starts with System default")
            return true
        }
        #expect(uid == nil)
    }

    @Test func resolveAsksOnlyUpToTheFirstConnected() {
        let list: [InputChoice] = [.device(uid: "a", name: "A"), .device(uid: "b", name: "B"), .device(uid: "c", name: "C"), .systemDefault]
        var asked: [String] = []
        let uid = InputChoice.resolve(list) { asked.append($0); return $0 == "b" }
        #expect(uid == "b")
        #expect(asked == ["a", "b"])
    }

    @Test func loadKeepsACleanStoredList() throws {
        let list: [InputChoice] = [.device(uid: "a", name: "A"), .systemDefault]
        let loaded = InputChoice.load(stored: try JSONEncoder().encode(list), legacyUID: "old") { _ in
            Issue.record("no migration for a stored list")
            return nil
        }
        #expect(loaded.list == list)
        #expect(!loaded.write)
    }

    @Test func loadRepairsAndWritesBack() throws {
        let a = InputChoice.device(uid: "a", name: "A")
        let loaded = InputChoice.load(stored: try JSONEncoder().encode([a, a]), legacyUID: nil) { _ in nil }
        #expect(loaded.list == [a, .systemDefault])
        #expect(loaded.write)
    }

    @Test func loadMigratesWhenNothingIsStored() {
        let loaded = InputChoice.load(stored: nil, legacyUID: "usb-1") { _ in "Webcam" }
        #expect(loaded.list == [.device(uid: "usb-1", name: "Webcam"), .systemDefault])
        #expect(loaded.write)
    }

    @Test func loadMigratesWhenTheStoredListIsUnreadable() {
        let loaded = InputChoice.load(stored: Data("not json".utf8), legacyUID: nil) { _ in nil }
        #expect(loaded.list == [.systemDefault])
        #expect(loaded.write)
    }
}
