import Foundation
import Testing
@testable import Roger

struct TolerantDecodingTests {
    private struct Item: Codable, Equatable {
        var name: String
        var size: Int
    }

    /// The JSON value of `data`, for comparing values instead of bytes.
    private func value(_ data: Data) throws -> NSObject {
        try #require(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject)
    }

    @Test func oneBadEntryIsSkippedAndTheOthersLoad() throws {
        let json = #"[{"name":"a","size":1},{"name":"b","size":"big"},{"other":true},{"name":"c","size":3}]"#
        let loaded = try #require(TolerantDecoding.load(Item.self, from: Data(json.utf8), label: "item"))
        #expect(loaded.values == [Item(name: "a", size: 1), Item(name: "c", size: 3)])
        #expect(try loaded.unreadable.map(value) == [
            try value(Data(#"{"name":"b","size":"big"}"#.utf8)),
            try value(Data(#"{"other":true}"#.utf8)),
        ])
    }

    @Test func notAnArrayIsNil() throws {
        #expect(TolerantDecoding.load(Item.self, from: Data(#"{"name":"a"}"#.utf8), label: "item") == nil)
        #expect(TolerantDecoding.load(Item.self, from: Data("nope".utf8), label: "item") == nil)
        let empty = try #require(TolerantDecoding.load(Item.self, from: Data("[]".utf8), label: "item"))
        #expect(empty.values.isEmpty && empty.unreadable.isEmpty)
    }

    @Test func withoutUnreadableEntriesTheListEncodesAsBefore() throws {
        let items = [Item(name: "a", size: 1)]
        #expect(try value(TolerantDecoding.encode(items, keeping: [])) == (try value(JSONEncoder().encode(items))))
    }

    @Test func anUnreadableEntrySurvivesAnEditAndASave() throws {
        let bad = #"{"name":"b","size":"big","newer":{"list":[1,2.5,"x"],"flag":false,"none":null}}"#
        let json = #"[{"name":"a","size":1},\#(bad),{"name":"c","size":3}]"#
        var loaded = try #require(TolerantDecoding.load(Item.self, from: Data(json.utf8), label: "item"))
        loaded.values[0].size = 10
        let saved = try TolerantDecoding.encode(loaded.values, keeping: loaded.unreadable)

        let array = try #require(try JSONSerialization.jsonObject(with: saved) as? [Any])
        #expect(array.count == 3)
        // The bad entry goes to the end, unchanged as a JSON value.
        let last = try JSONSerialization.data(withJSONObject: try #require(array.last))
        #expect(try value(last) == (try value(Data(bad.utf8))))

        // Loading again shows the edit and still keeps the bad entry.
        let again = try #require(TolerantDecoding.load(Item.self, from: saved, label: "item"))
        #expect(again.values == [Item(name: "a", size: 10), Item(name: "c", size: 3)])
        #expect(try again.unreadable.map(value) == [try value(Data(bad.utf8))])
    }

    @Test func aCommandFromANewerVersionSurvivesASave() throws {
        let newer = #"{"id":"11111111-2222-3333-4444-555555555555","name":"X","commandLine":"x","prompt":"","workingDirectory":"~","mode":"cloud"}"#
        let goodText = String(decoding: try JSONEncoder().encode(AgentCommand.blank()), as: UTF8.self)
        var loaded = try #require(TolerantDecoding.load(AgentCommand.self, from: Data("[\(newer),\(goodText)]".utf8), label: "command"))
        #expect(loaded.values.map(\.name) == ["New command"])
        loaded.values[0].name = "Edited"
        let saved = try TolerantDecoding.encode(loaded.values, keeping: loaded.unreadable)
        let again = try #require(TolerantDecoding.load(AgentCommand.self, from: saved, label: "command"))
        #expect(again.values.map(\.name) == ["Edited"])
        #expect(try again.unreadable.map(value) == [try value(Data(newer.utf8))])
    }

    @Test func aPresetThatCannotBeReadSurvivesASave() throws {
        let presets = [DictationPreset.plain, DictationPreset.polished]
        var array = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(presets)) as? [Any])
        let bad: [String: Any] = ["id": "not-a-uuid", "name": "From the future"]
        array.insert(bad, at: 1)
        let data = try JSONSerialization.data(withJSONObject: array)
        var loaded = try #require(TolerantDecoding.load(DictationPreset.self, from: data, label: "preset"))
        #expect(loaded.values.map(\.id) == presets.map(\.id))
        loaded.values[1].name = "Polished (edited)"
        let saved = try TolerantDecoding.encode(loaded.values, keeping: loaded.unreadable)
        let again = try #require(TolerantDecoding.load(DictationPreset.self, from: saved, label: "preset"))
        #expect(again.values.map(\.name) == ["Plain", "Polished (edited)"])
        #expect(try again.unreadable.map(value) == [try value(JSONSerialization.data(withJSONObject: bad))])
    }
}
