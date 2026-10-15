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
}
