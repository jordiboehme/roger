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
        for required in ["get_changes", "summary: true", "ack", "roger://", "$contains_any", "RESULT: ok more", "RESULT: failed:", "archived", "crystalline"] {
            #expect(text.contains(required), "missing \(required)")
        }
        #expect(!text.contains("\u{2014}"))
        #expect(!text.contains("\u{2013}"))
    }
}
