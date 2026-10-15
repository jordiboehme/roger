import Foundation
import Testing
@testable import Roger

struct DictationPresetTests {
    @Test func oldJSONWithoutNewFieldsDecodes() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-0000000000AA","name":"Old","isBuiltIn":false,
         "enableFillerRemoval":true,"enableDedup":true,"enableAIFormatting":false,
         "enableCustomDictionary":false,"enableRewrite":false,"aiPrompt":"",
         "rewritePrompt":"","dictionaryEntries":[]}
        """
        let preset = try JSONDecoder().decode(DictationPreset.self, from: Data(json.utf8))
        #expect(preset.output == .insertAtCursor)
        #expect(preset.keepAudio == false)
    }

    @Test func newFieldsRoundTrip() throws {
        var preset = DictationPreset.plain
        preset.output = .logEntry
        preset.keepAudio = true
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(DictationPreset.self, from: data)
        #expect(decoded.output == .logEntry)
        #expect(decoded.keepAudio == true)
    }

    @Test func logPresetIsBuiltIn() {
        let log = DictationPreset.log
        #expect(log.id == UUID(uuidString: "00000000-0000-0000-0000-000000000008"))
        #expect(log.output == .logEntry)
        #expect(log.keepAudio == false)
        #expect(log.excludedFromRotation == true)
        #expect(log.requiresAI == false)
        #expect(DictationPreset.builtInPresets.contains(log))
    }

    @Test func withoutAIKeepsOutputAndAudio() {
        var preset = DictationPreset.polished
        preset.output = .logEntry
        preset.keepAudio = true
        let fallback = preset.withoutAI
        #expect(fallback.requiresAI == false)
        #expect(fallback.output == .logEntry)
        #expect(fallback.keepAudio == true)
        #expect(fallback.enableCustomDictionary == preset.enableCustomDictionary)
        #expect(fallback.id == preset.id)
    }

    @Test func legacyPresetDecodesWithSystemAudioDefaults() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000008","name":"Log","isBuiltIn":true,
         "enableFillerRemoval":true,"enableDedup":true,"enableAIFormatting":false,
         "enableCustomDictionary":false,"enableRewrite":false,"aiPrompt":"","rewritePrompt":"",
         "dictionaryEntries":[],"output":"logEntry","keepAudio":true}
        """
        let preset = try JSONDecoder().decode(DictationPreset.self, from: Data(json.utf8))
        #expect(preset.recordSystemAudio == false)
        #expect(preset.commandID == nil)
        #expect(preset.keepAudio == true)
    }

    @Test func systemAudioAndCommandRoundTrip() throws {
        var preset = DictationPreset.log
        preset.recordSystemAudio = true
        preset.commandID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(DictationPreset.self, from: data)
        #expect(back == preset)
    }

    @Test func withoutAIKeepsSystemAudioAndCommand() {
        var preset = DictationPreset.log
        preset.recordSystemAudio = true
        preset.commandID = UUID()
        #expect(preset.withoutAI.recordSystemAudio == true)
        #expect(preset.withoutAI.commandID == preset.commandID)
    }

    @Test func builtInLogPresetShipsWithSystemAudioOff() {
        #expect(DictationPreset.log.recordSystemAudio == false)
        #expect(DictationPreset.log.commandID == nil)
    }
}
