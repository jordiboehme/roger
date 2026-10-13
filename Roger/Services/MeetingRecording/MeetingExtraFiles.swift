import Foundation

/// Files a retry can leave in a meeting folder: leftover and previous
/// audio archives, the previous transcript and previous segments. Nothing
/// here moves or deletes them.
enum MeetingExtraFiles {
    enum Kind: String, CaseIterable, Sendable {
        case micLeftover = "mic-leftover"
        case systemLeftover = "system-leftover"
        case micPrevious = "mic-previous"
        case systemPrevious = "system-previous"
        case transcriptPrevious = "transcript-previous"
        case segmentPrevious = "segment-previous"

        var isAudio: Bool {
            switch self {
            case .micLeftover, .systemLeftover, .micPrevious, .systemPrevious: return true
            case .transcriptPrevious, .segmentPrevious: return false
            }
        }
    }

    struct File: Equatable, Sendable {
        let url: URL
        let kind: Kind
        /// 0 for `x.leftover.m4a`, N for `x.leftover N.m4a`.
        let number: Int
    }

    /// Kind and number of an extra file name, or nil.
    static func classify(_ name: String) -> (kind: Kind, number: Int)? {
        if case let (stem, number)? = labeled(name, label: "leftover", ext: "m4a") {
            switch stem {
            case "mic": return (.micLeftover, number)
            case "system": return (.systemLeftover, number)
            default: return nil
            }
        }
        if case let (stem, number)? = labeled(name, label: "previous", ext: "m4a") {
            switch stem {
            case "mic": return (.micPrevious, number)
            case "system": return (.systemPrevious, number)
            default: return nil
            }
        }
        if case let (stem, number)? = labeled(name, label: "previous", ext: "md") {
            return (stem == "transcript" ? .transcriptPrevious : .segmentPrevious, number)
        }
        return nil
    }

    /// Extra files in `folder`, ordered by kind, then number.
    static func find(in folder: URL) -> [File] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let order = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        return names
            .compactMap { name in
                classify(name).map { File(url: folder.appendingPathComponent(name), kind: $0.kind, number: $0.number) }
            }
            .sorted { a, b in
                if a.kind != b.kind { return order[a.kind, default: 0] < order[b.kind, default: 0] }
                if a.number != b.number { return a.number < b.number }
                return a.url.lastPathComponent < b.url.lastPathComponent
            }
    }

    /// `sources` entries for the extra audio files, so agents see them:
    /// ids `mic-leftover`, `mic-leftover-2`, `mic-leftover-3` … per kind,
    /// in file order.
    static func audioSources(in folder: URL) -> [TranscriptFrontmatter.Source] {
        var counts: [Kind: Int] = [:]
        return find(in: folder).filter(\.kind.isAudio).map { file in
            let n = counts[file.kind, default: 0] + 1
            counts[file.kind] = n
            let id = n == 1 ? file.kind.rawValue : "\(file.kind.rawValue)-\(n)"
            return TranscriptFrontmatter.Source(id: id, resource: file.url.lastPathComponent)
        }
    }

    /// `<stem>.<label>.<ext>` gives (stem, 0); `<stem>.<label> N.<ext>` gives (stem, N).
    private static func labeled(_ name: String, label: String, ext: String) -> (stem: String, number: Int)? {
        let suffix = "." + ext
        guard name.hasSuffix(suffix) else { return nil }
        let base = String(name.dropLast(suffix.count))
        let marker = "." + label
        if base.hasSuffix(marker) {
            let stem = String(base.dropLast(marker.count))
            return stem.isEmpty ? nil : (stem, 0)
        }
        guard let range = base.range(of: marker + " ", options: .backwards) else { return nil }
        let digits = base[range.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let number = Int(digits) else { return nil }
        let stem = String(base[..<range.lowerBound])
        return stem.isEmpty ? nil : (stem, number)
    }
}
