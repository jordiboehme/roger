import Foundation
import Testing
@testable import Roger

struct PresetEditingTests {
    @Test func resetBringsBackTheShippedPreset() {
        var preset = DictationPreset.polished
        preset.name = "Mine"
        preset.language = "de"
        preset.enableRewrite = true
        preset.aiPrompt = "x"
        preset.output = .logEntry
        preset.dictionaryEntries = [DictionaryEntry(find: "roger", replace: "Roger")]
        #expect(preset.isChangedBuiltIn)
        let reset = preset.resetToOriginal()
        #expect(reset == DictationPreset.polished)
        #expect(!reset.isChangedBuiltIn)
    }

    @Test func resetKeepsTheRotationChoice() {
        var preset = DictationPreset.log
        preset.excludedFromRotation = false
        #expect(!preset.isChangedBuiltIn)
        preset.keepAudio = true
        let reset = preset.resetToOriginal()
        #expect(reset.keepAudio == false)
        #expect(reset.excludedFromRotation == false)
        #expect(reset.id == DictationPreset.log.id)
    }

    @Test func customPresetsHaveNoOriginal() {
        let custom = DictationPreset.newCustom()
        #expect(custom.original == nil)
        #expect(!custom.isChangedBuiltIn)
        #expect(custom.resetToOriginal() == custom)
        #expect(!custom.isBuiltIn)
    }

    @Test func duplicateIsACustomCopy() {
        let copy = DictationPreset.code.duplicated()
        #expect(copy.id != DictationPreset.code.id)
        #expect(copy.name == "Code Copy")
        #expect(!copy.isBuiltIn)
        #expect(copy.aiPrompt == DictationPreset.code.aiPrompt)
        #expect(copy.original == nil)
    }

    @Test func dictionarySummaryCountsWords() {
        var preset = DictationPreset.newCustom()
        #expect(preset.dictionarySummary == "No words")
        preset.dictionaryEntries = [DictionaryEntry(find: "a", replace: "b")]
        #expect(preset.dictionarySummary == "1 word")
        preset.dictionaryEntries.append(DictionaryEntry(find: "c", replace: "d"))
        #expect(preset.dictionarySummary == "2 words")
    }
}

@MainActor
struct PresetLanguageWarningTests {
    @Test func noWarningWithoutAPinOrWithoutAI() {
        var preset = DictationPreset.polished
        #expect(PresetsPane.languageWarning(preset: preset, provider: .appleIntelligence) == nil)
        preset.language = "en"
        #expect(PresetsPane.languageWarning(preset: preset, provider: .appleIntelligence) == nil)
        var plain = DictationPreset.plain
        plain.language = "fi"
        #expect(PresetsPane.languageWarning(preset: plain, provider: .appleIntelligence) == nil)
        var cloud = DictationPreset.polished
        cloud.language = "fi"
        #expect(PresetsPane.languageWarning(preset: cloud, provider: .claude) == nil)
    }
}
