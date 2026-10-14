import Foundation

/// A JSON value from a tool call, without depending on the MCP SDK.
public enum ToolValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ToolValue])
    case object([String: ToolValue])
    case null
}

/// What a tool answers: text, and whether it is an error the agent should
/// read (MCP `isError`).
public struct ToolOutput: Equatable, Sendable {
    public let text: String
    public let isError: Bool

    public static func ok(_ text: String) -> ToolOutput { ToolOutput(text: text, isError: false) }
    public static func error(_ text: String) -> ToolOutput { ToolOutput(text: text, isError: true) }
}

/// A problem with the arguments or the library, answered as `isError`.
struct ToolFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Typed access to the arguments. Agents send numbers as integers, whole
/// doubles or digit strings; all three are accepted.
struct ToolArguments {
    let values: [String: ToolValue]

    func has(_ name: String) -> Bool {
        guard let value = values[name] else { return false }
        return value != .null
    }

    func string(_ name: String) throws -> String? {
        switch values[name] {
        case nil, .null?: return nil
        case .string(let text)?: return text
        default: throw ToolFailure("\(name) must be a string.")
        }
    }

    func int(_ name: String) throws -> Int? {
        switch values[name] {
        case nil, .null?: return nil
        case .int(let number)?: return number
        case .double(let number)? where number.rounded() == number && abs(number) < 1e15: return Int(number)
        case .string(let text)? where Int(text) != nil: return Int(text)
        default: throw ToolFailure("\(name) must be a whole number.")
        }
    }

    func bool(_ name: String) throws -> Bool? {
        switch values[name] {
        case nil, .null?: return nil
        case .bool(let flag)?: return flag
        case .string("true")?: return true
        case .string("false")?: return false
        default: throw ToolFailure("\(name) must be true or false.")
        }
    }

    func strings(_ name: String) throws -> [String]? {
        switch values[name] {
        case nil, .null?: return nil
        case .string(let text)?: return [text]
        case .array(let items)?:
            return try items.map {
                guard case .string(let text) = $0 else { throw ToolFailure("\(name) must be a list of strings.") }
                return text
            }
        default: throw ToolFailure("\(name) must be a list of strings.")
        }
    }

    /// `since` as text: integers become their digits.
    func sinceText(_ name: String) throws -> String? {
        if case .string(let text)? = values[name] { return text }
        return try int(name).map(String.init)
    }
}
