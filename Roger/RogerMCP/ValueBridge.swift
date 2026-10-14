import MCP
import RogerKit

/// MCP `Value` to RogerKit's `ToolValue`, so RogerKit never imports MCP.
enum ValueBridge {
    static func arguments(_ values: [String: Value]?) -> [String: ToolValue] {
        (values ?? [:]).mapValues(toolValue)
    }

    static func toolValue(_ value: Value) -> ToolValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .int(let number): return .int(number)
        case .double(let number): return .double(number)
        case .string(let text): return .string(text)
        case .data(_, let data): return .string(data.base64EncodedString())
        case .array(let items): return .array(items.map(toolValue))
        case .object(let fields): return .object(fields.mapValues(toolValue))
        }
    }
}
