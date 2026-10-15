import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Settings")

/// Reads a saved list entry by entry, so one entry Roger cannot read (for
/// example one written by a newer version) does not lose the others. Such
/// an entry is kept as its raw JSON and written back unchanged, so a save
/// never drops it.
enum TolerantDecoding {
    /// A list as loaded: the entries Roger can read, in order, and the raw
    /// JSON of the others, in order.
    struct Loaded<Value> {
        var values: [Value]
        var unreadable: [Data]
    }

    /// Splits the JSON array in `data` into entries that decode as `T` and
    /// the raw JSON of those that do not. Each failure is logged with its
    /// position. Nil when `data` is no JSON array at all.
    static func load<T: Decodable>(_ type: T.Type, from data: Data, label: String,
                                   decoder: JSONDecoder = JSONDecoder()) -> Loaded<T>? {
        guard let entries = try? decoder.decode([Entry<T>].self, from: data) else { return nil }
        var loaded = Loaded<T>(values: [], unreadable: [])
        var raw: [Any]?
        for (index, entry) in entries.enumerated() {
            switch entry.result {
            case .success(let value):
                loaded.values.append(value)
            case .failure(let error):
                logger.error("Skipped \(label, privacy: .public) \(index + 1) of \(entries.count): \(String(describing: error), privacy: .public)")
                if raw == nil { raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] }
                if let element = raw?[index],
                   let json = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed]) {
                    loaded.unreadable.append(json)
                }
            }
        }
        return loaded
    }

    /// The `"id"` UUIDs of raw entries that have one.
    static func ids(in unreadable: [Data]) -> Set<UUID> {
        Set(unreadable.compactMap { entry in
            let object = try? JSONSerialization.jsonObject(with: entry, options: [.fragmentsAllowed]) as? [String: Any]
            return (object?["id"] as? String).flatMap(UUID.init(uuidString:))
        })
    }

    /// `values` as a JSON array, followed by the `unreadable` entries
    /// unchanged. They go at the end, because the list may have changed
    /// around their old position.
    static func encode<T: Encodable>(_ values: [T], keeping unreadable: [Data],
                                     encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let data = try encoder.encode(values)
        guard !unreadable.isEmpty else { return data }
        var array = try JSONSerialization.jsonObject(with: data) as? [Any] ?? []
        for entry in unreadable {
            array.append(try JSONSerialization.jsonObject(with: entry, options: [.fragmentsAllowed]))
        }
        return try JSONSerialization.data(withJSONObject: array, options: [.fragmentsAllowed])
    }

    /// Never fails itself, so the array goes on to the next entry.
    private struct Entry<Value: Decodable>: Decodable {
        let result: Result<Value, Error>

        init(from decoder: Decoder) throws {
            result = Result { try Value(from: decoder) }
        }
    }
}
