import Foundation

/// A primitive TOON value.
public enum TOONValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
}

/// The part of TOON 4.4 (github.com/toon-format/spec, 2026-10-08) that
/// Roger writes: key-value lines, nested objects, inline primitive arrays
/// and tabular arrays. Comma delimiter, two spaces per level, no trailing
/// spaces, no blank lines inside a block.
public enum TOON {
    public static let indentUnit = "  "

    public static func encode(_ value: TOONValue) -> String {
        switch value {
        case .string(let text): return string(text)
        case .int(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// The string as is, or quoted when §7.2 requires it.
    public static func string(_ text: String) -> String {
        needsQuotes(text) ? quoted(text) : text
    }

    /// TOON 4.4 §7.2 with the comma as document delimiter.
    public static func needsQuotes(_ text: String) -> Bool {
        if text.isEmpty { return true }
        if let first = text.unicodeScalars.first, first == " " || first == "\t" { return true }
        if let last = text.unicodeScalars.last, last == " " || last == "\t" { return true }
        if text == "true" || text == "false" || text == "null" { return true }
        if text.range(of: #"^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil { return true }
        if text.hasPrefix("-") || text.hasPrefix("#") { return true }
        for scalar in text.unicodeScalars {
            switch scalar {
            case ":", "\"", "\\", "[", "]", "{", "}", ",":
                return true
            default:
                if scalar.value < 0x20 { return true }
            }
        }
        return false
    }

    /// Double-quoted with the escapes of §7.1: `\\`, `\"`, `\n`, `\r`,
    /// `\t`, other controls as `\uXXXX` with lowercase hex.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// §7.3: unquoted when it matches `^[A-Za-z_][A-Za-z0-9_.]*$`.
    public static func key(_ name: String) -> String {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil ? name : quoted(name)
    }

    /// `name: value`
    public static func field(_ name: String, _ value: TOONValue, depth: Int = 0) -> String {
        indent(depth) + key(name) + ": " + encode(value)
    }

    /// `name:` opening a nested object; its fields follow at `depth + 1`.
    public static func object(_ name: String, depth: Int = 0) -> String {
        indent(depth) + key(name) + ":"
    }

    /// `name[N]: a,b` or `name: []`.
    public static func inlineArray(_ name: String, _ values: [TOONValue], depth: Int = 0) -> String {
        guard !values.isEmpty else { return indent(depth) + key(name) + ": []" }
        return indent(depth) + key(name) + "[\(values.count)]: " + values.map(encode).joined(separator: ",")
    }

    /// `name[N]{f1,f2}:` and one row per record, or `name: []`.
    public static func table(_ name: String, fields: [String], rows: [[TOONValue]], depth: Int = 0) -> String {
        guard !rows.isEmpty else { return indent(depth) + key(name) + ": []" }
        var lines = [indent(depth) + key(name) + "[\(rows.count)]{" + fields.map(key).joined(separator: ",") + "}:"]
        for row in rows {
            precondition(row.count == fields.count, "A TOON row needs one cell per field")
            lines.append(indent(depth + 1) + row.map(encode).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func indent(_ depth: Int) -> String {
        String(repeating: indentUnit, count: depth)
    }
}
