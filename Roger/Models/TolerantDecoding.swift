import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Settings")

/// Reads a saved list entry by entry, so one entry Roger cannot read (for
/// example one written by a newer version) does not lose the others.
enum TolerantDecoding {
    /// The entries of the JSON array in `data` that decode as `T`, in
    /// order. An entry that fails is skipped and logged with its position.
    /// Nil when `data` is no JSON array at all.
    static func array<T: Decodable>(of type: T.Type, from data: Data, label: String,
                                    decoder: JSONDecoder = JSONDecoder()) -> [T]? {
        guard let entries = try? decoder.decode([Entry<T>].self, from: data) else { return nil }
        var result: [T] = []
        for (index, entry) in entries.enumerated() {
            switch entry.result {
            case .success(let value):
                result.append(value)
            case .failure(let error):
                logger.error("Skipped \(label, privacy: .public) \(index + 1) of \(entries.count): \(String(describing: error), privacy: .public)")
            }
        }
        return result
    }

    /// Never fails itself, so the array goes on to the next entry.
    private struct Entry<Value: Decodable>: Decodable {
        let result: Result<Value, Error>

        init(from decoder: Decoder) throws {
            result = Result { try Value(from: decoder) }
        }
    }
}
