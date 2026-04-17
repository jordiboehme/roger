import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "PostProcessor")

struct PostProcessor: Sendable {

    func process(_ text: String, preset: DictationPreset, language: String, llmService: (any LLMService)?) async throws -> String {
        var result = text

        if preset.enableFillerRemoval {
            result = removeFillerWords(from: result)
            logger.debug("After filler removal: \(result)")
        }

        if preset.enableDedup {
            result = deduplicateWords(in: result)
            logger.debug("After dedup: \(result)")
        }

        let languageContext = "The text is in \(language). Do not translate it — keep it in \(language)."

        // When both AI steps are enabled, combine them into a single call to
        // halve latency. The dictionary then always runs last so user-defined
        // replacements have the final word.
        if preset.enableAIFormatting && preset.enableRewrite {
            guard let llm = llmService else {
                throw PostProcessingError.noAIProviderAvailable
            }
            let prompt = """
            Apply two transformations to the text, in order, and return ONLY the final result — no step labels, no explanations, no markdown fences.

            --- Transformation 1 ---
            \(preset.aiPrompt)

            --- Transformation 2 (applied to the output of Transformation 1) ---
            \(preset.rewritePrompt)

            \(languageContext)
            """
            result = try await llm.processText(result, prompt: prompt)
            logger.debug("After merged AI formatting + rewrite: \(result)")
        } else if preset.enableAIFormatting {
            guard let llm = llmService else {
                throw PostProcessingError.noAIProviderAvailable
            }
            let prompt = "\(preset.aiPrompt)\n\n\(languageContext)"
            result = try await llm.processText(result, prompt: prompt)
            logger.debug("After AI formatting: \(result)")
        } else if preset.enableRewrite {
            guard let llm = llmService else {
                throw PostProcessingError.noAIProviderAvailable
            }
            let prompt = "\(preset.rewritePrompt)\n\n\(languageContext)"
            result = try await llm.processText(result, prompt: prompt)
            logger.debug("After rewrite: \(result)")
        }

        if preset.enableCustomDictionary {
            result = applyDictionary(result, entries: preset.dictionaryEntries)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filler Word Removal

    private static let fillerWords: Set<String> = [
        // English
        "um", "uh", "uh huh", "uhh", "umm", "hmm", "hm",
        "you know", "like", "I mean", "sort of", "kind of",
        "basically", "actually", "literally", "right",
        // German
        "äh", "ähm", "mhm", "halt", "also", "sozusagen",
        "quasi", "irgendwie", "na ja", "naja", "genau",
    ]

    private func removeFillerWords(from text: String) -> String {
        var result = text
        // Sort by length descending so multi-word fillers are matched first
        let sorted = Self.fillerWords.sorted { $0.count > $1.count }
        for filler in sorted {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        // Collapse multiple spaces and trim
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Repeated Word Dedup

    private func deduplicateWords(in text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "\\b(\\w+)\\s+\\1\\b", options: .caseInsensitive) else {
            return result
        }

        var previous = ""
        while result != previous {
            previous = result
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        return result
    }

    // MARK: - Dictionary Replacement

    private func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> String {
        var result = text
        for entry in entries where !entry.find.isEmpty {
            result = result.replacingOccurrences(of: entry.find, with: entry.replace)
        }
        return result
    }
}
