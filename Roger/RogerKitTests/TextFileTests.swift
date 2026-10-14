import Foundation
import Testing
@testable import RogerKit

struct TextFileTests {
    @Test(arguments: TextSample.allCases)
    func everyVariantDecodesToUTF8WithLF(_ sample: TextSample) {
        #expect(TextFile.decode(sample.data) == TextSample.text)
    }

    @Test func lineEndings() {
        #expect(TextFile.normalizeLineEndings("a\r\nb\rc\nd") == "a\nb\nc\nd")
        #expect(TextFile.normalizeLineEndings("a\r\r\nb") == "a\n\nb")
        #expect(TextFile.normalizeLineEndings("a\n\rb") == "a\n\nb")
        #expect(TextFile.normalizeLineEndings("end\r") == "end\n")
        #expect(TextFile.normalizeLineEndings("plain") == "plain")
    }

    @Test func bomIsNotPartOfTheText() {
        #expect(TextFile.decode(Data([0xEF, 0xBB, 0xBF, 0x41])) == "A")
        #expect(TextFile.decode(Data([0xFE, 0xFF, 0x00, 0x41])) == "A")
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x41, 0x00])) == "A")
        #expect(TextFile.decode(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41])) == "A")
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])) == "A")
    }

    @Test func brokenBOMFilesStillDecode() {
        // Odd byte count after a UTF-16 BOM, a lone surrogate, a short UTF-32 tail.
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0x42])) == "A\u{FFFD}")
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00])) == "\u{FFFD}A")
        #expect(TextFile.decode(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00])) == "\u{FFFD}")
        #expect(TextFile.decode(Data([0xEF, 0xBB, 0xBF, 0xFF])) == "\u{FFFD}")
    }

    @Test func windows1252MapsEveryByte() {
        let undefined: [UInt8] = [0x81, 0x8D, 0x8F, 0x90, 0x9D]
        // Foundation refuses these; Roger maps them like Latin-1.
        #expect(String(data: Data(undefined), encoding: .windowsCP1252) == nil)
        #expect(TextFile.decode(Data(undefined)).unicodeScalars.map(\.value) == [0x81, 0x8D, 0x8F, 0x90, 0x9D])
        #expect(TextFile.decode(Data([0x80, 0x93, 0x94, 0xE4, 0xDF])) == "€“”äß")
        let all = TextFile.decode(Data((0...255).map { UInt8($0) } + [0xFF]))
        #expect(all.unicodeScalars.count == 257)
    }

    @Test func validUTF8WinsOverWindows1252() {
        #expect(TextFile.decode(Data("Grüße".utf8)) == "Grüße")
        #expect(TextFile.decode(Data([0x47, 0x72, 0xFC, 0xDF, 0x65])) == "Grüße")
    }

    @Test func readThrowsOnlyFileErrors() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        #expect(throws: (any Error).self) { try TextFile.read(folder.appendingPathComponent("missing.md")) }
        let url = try TextSample.windows1252.write(to: folder.appendingPathComponent("w.md"))
        #expect(try TextFile.read(url) == TextSample.text)
    }
}
