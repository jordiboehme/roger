import Foundation

/// The one way Roger reads text files: UTF-8 text with LF line endings,
/// whatever encoding or line endings the file has. Roger never rewrites a
/// file just to convert it; files it writes anyway are UTF-8 with LF.
public enum TextFile {
    /// Reads a text file as UTF-8 with LF line endings. Throws only the
    /// file system error (missing file, no permission), never an encoding
    /// error.
    public static func read(_ url: URL) throws -> String {
        decode(try Data(contentsOf: url))
    }

    /// Decodes bytes: a BOM (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE) first, then
    /// UTF-8, then Windows-1252. Never fails. The BOM is not part of the
    /// result. Line endings become LF.
    public static func decode(_ data: Data) -> String {
        normalizeLineEndings(decodeBytes([UInt8](data)))
    }

    /// `\r\n` and a lone `\r` become `\n`. Works on Unicode scalars: in a
    /// Swift `String`, `"\r\n"` is one `Character`.
    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        var out = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                afterCR = true
                continue
            }
            if scalar == "\n", afterCR {
                afterCR = false
                continue
            }
            afterCR = false
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Decoding

    private static func decodeBytes(_ bytes: [UInt8]) -> String {
        // UTF-32 LE before UTF-16 LE: both start with FF FE.
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return utf32(bytes.dropFirst(4), bigEndian: true) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return utf32(bytes.dropFirst(4), bigEndian: false) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFE, 0xFF]) { return utf16(bytes.dropFirst(2), bigEndian: true) }
        if bytes.starts(with: [0xFF, 0xFE]) { return utf16(bytes.dropFirst(2), bigEndian: false) }
        if let text = String(validating: bytes, as: UTF8.self) { return text }
        return windows1252(bytes)
    }

    /// Pairs of bytes; a lone surrogate or a last odd byte becomes U+FFFD.
    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2 + 1)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            units.append(bigEndian ? (a << 8 | b) : (b << 8 | a))
            index += 2
        }
        var text = String(decoding: units, as: UTF16.self)
        if index < bytes.endIndex { text.unicodeScalars.append("\u{FFFD}") }
        return text
    }

    /// Groups of four bytes; an invalid scalar or a short tail becomes U+FFFD.
    private static func utf32(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var index = bytes.startIndex
        while index + 3 < bytes.endIndex {
            let quad = (0..<4).map { UInt32(bytes[index + $0]) }
            let value = bigEndian
                ? (quad[0] << 24 | quad[1] << 16 | quad[2] << 8 | quad[3])
                : (quad[3] << 24 | quad[2] << 16 | quad[1] << 8 | quad[0])
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            index += 4
        }
        if index < bytes.endIndex { scalars.append("\u{FFFD}") }
        return String(scalars)
    }

    /// 0x80 to 0x9F per Windows-1252. The five bytes it leaves undefined
    /// (0x81, 0x8D, 0x8F, 0x90, 0x9D) and every other byte map to the same
    /// code point as in Latin-1. Foundation's `.windowsCP1252` refuses the
    /// whole text when one of the five appears, so the table is Roger's own.
    private static let cp1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private static func windows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            let value = (0x80...0x9F).contains(byte) ? cp1252High[Int(byte) - 0x80] : UInt32(byte)
            // Every table value is a valid scalar.
            scalars.append(Unicode.Scalar(value)!)
        }
        return String(scalars)
    }
}
