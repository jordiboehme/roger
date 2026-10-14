import Testing
@testable import RogerKit

struct TOONTests {
    @Test(arguments: [
        ("Hello world", "Hello world"),
        ("Grüße 🎉", "Grüße 🎉"),
        ("/Users/x/Documents/Roger/Logs/2026/10/2026-10-13 14-32-05.md", "/Users/x/Documents/Roger/Logs/2026/10/2026-10-13 14-32-05.md"),
        ("Logs/2026/10/2026-10-13 14-32-05", "Logs/2026/10/2026-10-13 14-32-05"),
        ("", "\"\""),
        (" lead", "\" lead\""),
        ("trail ", "\"trail \""),
        ("true", "\"true\""),
        ("null", "\"null\""),
        ("42", "\"42\""),
        ("-3.14", "\"-3.14\""),
        ("1e-6", "\"1e-6\""),
        ("05", "\"05\""),
        ("a:b", "\"a:b\""),
        ("2026-10-13T14:32:41+02:00", "\"2026-10-13T14:32:41+02:00\""),
        ("a,b", "\"a,b\""),
        ("[x]", "\"[x]\""),
        ("{x}", "\"{x}\""),
        ("- item", "\"- item\""),
        ("#tag", "\"#tag\""),
        ("line\nbreak", "\"line\\nbreak\""),
        ("tab\there", "\"tab\\there\""),
        ("cr\rhere", "\"cr\\rhere\""),
        ("bell\u{07}", "\"bell\\u0007\""),
        ("say \"hi\" \\ bye", "\"say \\\"hi\\\" \\\\ bye\""),
    ])
    func strings(input: String, expected: String) {
        #expect(TOON.string(input) == expected)
    }

    @Test func primitives() {
        #expect(TOON.encode(.int(42)) == "42")
        #expect(TOON.encode(.int(-1)) == "-1")
        #expect(TOON.encode(.bool(true)) == "true")
        #expect(TOON.encode(.null) == "null")
    }

    @Test func keys() {
        #expect(TOON.key("upTo") == "upTo")
        #expect(TOON.key("a.b_c") == "a.b_c")
        #expect(TOON.key("my-key") == "\"my-key\"")
        #expect(TOON.key("1st") == "\"1st\"")
    }

    @Test func fieldsAndObjects() {
        #expect(TOON.field("more", .bool(false)) == "more: false")
        #expect(TOON.field("log", .int(3), depth: 1) == "  log: 3")
        #expect(TOON.object("items") == "items:")
    }

    @Test func inlineArrays() {
        #expect(TOON.inlineArray("paths", [.string("/a b.md"), .string("/c,d.m4a")]) == "paths[2]: /a b.md,\"/c,d.m4a\"")
        #expect(TOON.inlineArray("paths", []) == "paths: []")
    }

    @Test func tables() {
        let text = TOON.table(
            "consumers",
            fields: ["name", "seq", "updatedAt"],
            rows: [
                [.string("crystalline"), .int(40), .string("2026-10-13T18:02:11+02:00")],
                [.string("notes-bot"), .int(0), .null],
            ]
        )
        #expect(text == """
        consumers[2]{name,seq,updatedAt}:
          crystalline,40,"2026-10-13T18:02:11+02:00"
          notes-bot,0,null
        """)
        #expect(TOON.table("items", fields: ["key"], rows: []) == "items: []")
    }

    /// Guard test: it passed before the hand-written check (the regex already
    /// rejected "abc\n"), and it keeps that so.
    @Test func keysWithATrailingNewlineAreQuoted() {
        #expect(TOON.key("abc\n") == "\"abc\\n\"")
        #expect(TOON.key("_a1") == "_a1")
        #expect(TOON.key("") == "\"\"")
        #expect(TOON.key("ä") == "\"ä\"")
    }

    @Test(arguments: ["1", "-1", "+2", "3.5", "1e9", "2E-3", "-0.5e+7"])
    func numbersAreQuoted(_ text: String) {
        #expect(TOON.looksLikeNumber(text))
        #expect(TOON.needsQuotes(text))
    }

    @Test(arguments: ["", "-", "1.", ".5", "1e", "1e+", "12a", "1.2.3", "0x10", "١٢"])
    func otherTextIsNoNumber(_ text: String) {
        #expect(!TOON.looksLikeNumber(text))
    }
}
