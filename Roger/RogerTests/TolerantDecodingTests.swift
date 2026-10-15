import Foundation
import Testing
@testable import Roger

struct TolerantDecodingTests {
    private struct Item: Codable, Equatable {
        let name: String
        let size: Int
    }

    @Test func oneBadEntryIsSkippedAndTheOthersLoad() throws {
        let json = #"[{"name":"a","size":1},{"name":"b","size":"big"},{"other":true},{"name":"c","size":3}]"#
        let items = try #require(TolerantDecoding.array(of: Item.self, from: Data(json.utf8), label: "item"))
        #expect(items == [Item(name: "a", size: 1), Item(name: "c", size: 3)])
    }

    @Test func notAnArrayIsNil() {
        #expect(TolerantDecoding.array(of: Item.self, from: Data(#"{"name":"a"}"#.utf8), label: "item") == nil)
        #expect(TolerantDecoding.array(of: Item.self, from: Data("nope".utf8), label: "item") == nil)
        #expect(TolerantDecoding.array(of: Item.self, from: Data("[]".utf8), label: "item") == [])
    }

    @Test func aCommandFromANewerVersionIsSkipped() throws {
        let good = try JSONEncoder().encode(AgentCommand.blank())
        let goodText = String(decoding: good, as: UTF8.self)
        let newer = #"{"id":"11111111-2222-3333-4444-555555555555","name":"X","commandLine":"x","prompt":"","workingDirectory":"~","mode":"cloud"}"#
        let commands = try #require(TolerantDecoding.array(of: AgentCommand.self, from: Data("[\(newer),\(goodText)]".utf8), label: "command"))
        #expect(commands.count == 1)
        #expect(commands.first?.name == "New command")
    }

    @Test func aPresetThatCannotBeReadIsSkipped() throws {
        let presets = [DictationPreset.plain, DictationPreset.polished]
        var array = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(presets)) as? [Any])
        array.insert(["id": "not-a-uuid"], at: 1)
        let data = try JSONSerialization.data(withJSONObject: array)
        let loaded = try #require(TolerantDecoding.array(of: DictationPreset.self, from: data, label: "preset"))
        #expect(loaded.map(\.id) == presets.map(\.id))
    }
}
