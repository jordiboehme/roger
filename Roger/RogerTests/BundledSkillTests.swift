import Foundation
import Testing
@testable import Roger

struct BundledSkillTests {
    /// `skills/ingest-roger/SKILL.md` in the repository.
    private var repositoryCopy: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("skills/ingest-roger/SKILL.md")
    }

    @Test func theAppBundlesTheRepositorySkill() throws {
        let skill = try #require(BundledSkill.load())
        #expect(skill.content == (try Data(contentsOf: repositoryCopy)))
        #expect(skill.version == Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        #expect(skill.sha256.count == 64)
        #expect(skill.sha256 == SkillHash.sha256(skill.content))
    }

    @Test func skillFollowsTheProtocolAndTheStyleRules() throws {
        let text = try String(contentsOf: repositoryCopy, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: ingest-roger\ndescription: "))
        for required in ["get_changes", "summary: true", "ack", "library: <library from step 1>", "roger://", "seq", "get_item", "list_items", "search", "RESULT: ok more", "RESULT: failed:", "crystalline-capture", "Ingesting a source", "frontmatter"] {
            #expect(text.contains(required), "SKILL.md lacks \(required)")
        }
        for forbidden in ["$contains_any", "archived", "What to write", "Never guess a domain"] {
            #expect(!text.contains(forbidden), "SKILL.md still has \(forbidden)")
        }
        #expect(!text.contains("\u{2014}"))
        #expect(!text.contains("\u{2013}"))
    }
}
