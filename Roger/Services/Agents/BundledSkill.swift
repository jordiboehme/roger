import CryptoKit
import Foundation

enum SkillHash {
    /// Lowercase hex SHA-256.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The ingest skill shipped inside Roger.app. Its version is the app
/// version; its hash decides whether an installed copy changed.
struct BundledSkill: Equatable, Sendable {
    static let name = "ingest-roger"

    let content: Data
    let version: String

    init(content: Data, version: String) {
        self.content = content
        self.version = version
    }

    var sha256: String { SkillHash.sha256(content) }

    static func load(from bundle: Bundle = .main) -> BundledSkill? {
        guard let url = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "skills/\(name)"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return BundledSkill(content: data, version: version)
    }
}
