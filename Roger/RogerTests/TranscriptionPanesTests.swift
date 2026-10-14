import CoreAudio
import Foundation
import SwiftUI
import Testing
@testable import Roger

@MainActor
struct TranscriptionPanesTests {
    @Test func transportNames() {
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeBuiltIn) == "Built-in")
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeUSB) == "USB")
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeBluetoothLE) == "Bluetooth")
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeContinuityCaptureWireless) == "iPhone")
        #expect(AudioDeviceLookup.transportName(forType: 0) == nil)
    }

    @Test func deviceNoteSaysWhatRogerRecordsFrom() {
        #expect(MicrophonePane.deviceNote(isAutomatic: true, deviceName: "MacBook Pro Microphone", transport: "Built-in", isConnected: true)
            == "Now: MacBook Pro Microphone, Built-in. Follows the macOS setting.")
        #expect(MicrophonePane.deviceNote(isAutomatic: false, deviceName: "Shure MV7", transport: "USB", isConnected: true)
            == "Shure MV7, USB")
        #expect(MicrophonePane.deviceNote(isAutomatic: false, deviceName: nil, transport: nil, isConnected: false)
            == "The saved device is not connected. Roger uses the system default until it is back.")
        #expect(MicrophonePane.deviceNote(isAutomatic: true, deviceName: nil, transport: nil, isConnected: true)
            == "Now: No input device. Follows the macOS setting.")
    }

    @Test func providerMenuSaysWhereTextGoes() {
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligence: .available) == "Apple Intelligence (local)")
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligence: .unavailable(.needsMacOS26)) == "Apple Intelligence (macOS 26 or later)")
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligence: .unavailable(.notEnabled)) == "Apple Intelligence (not available)")
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligence: .unavailable(.deviceNotEligible)) == "Apple Intelligence (not available)")
        #expect(AIProviderPane.menuTitle(.ollama, appleIntelligence: .available) == "Ollama (local)")
        #expect(AIProviderPane.menuTitle(.claude, appleIntelligence: .available) == "Claude (cloud)")
        #expect(AIProviderPane.menuTitle(.openai, appleIntelligence: .unavailable(.notEnabled)) == "OpenAI (cloud)")
    }

    @Test func testResultsColorBySuccessNotByWording() {
        #expect(SettingsTestResult.color(for: nil) == .secondary)
        #expect(SettingsTestResult.color(for: .success("Works. Roger saw the key.")) == .green)
        #expect(SettingsTestResult.color(for: .failure("No key press in 10 seconds.")) == .red)
        struct Boom: LocalizedError { var errorDescription: String? { "The device is busy." } }
        #expect(SettingsTestResult.failure(Boom()) == .failure("Failed: The device is busy."))
    }

    @Test func filesOutputNoteNamesTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/Lib/Transcripts", isDirectory: true)
        #expect(FilesPane.outputNote(.library, transcriptsFolder: folder) == "/tmp/Lib/Transcripts/YYYY/MM")
        #expect(FilesPane.outputNote(.alongsideSource, transcriptsFolder: folder)
            == "In the folder of the dropped file, as <file name>.md.")
    }

    /// The preset in use for files and meetings: the stored one when it
    /// needs no AI, else the user's Plain (also when renamed).
    @Test func localPresetResolverFallsBackToTheUsersPlain() {
        var presets = DictationPreset.builtInPresets
        let local = presets.first { !$0.requiresAI && $0.id != DictationPreset.plain.id }!
        let ai = presets.first { $0.requiresAI }!
        #expect(DictationPreset.localPreset(id: local.id, in: presets).id == local.id)
        #expect(DictationPreset.localPreset(id: ai.id, in: presets).id == DictationPreset.plain.id)
        #expect(DictationPreset.localPreset(id: UUID(), in: presets).id == DictationPreset.plain.id)

        let plainIndex = presets.firstIndex { $0.id == DictationPreset.plain.id }!
        presets[plainIndex].name = "Basic"
        #expect(DictationPreset.localPreset(id: UUID(), in: presets).name == "Basic")

        // An edited Plain with AI steps is no fallback: the original Plain is.
        presets[plainIndex].enableRewrite = true
        let fallback = DictationPreset.localPreset(id: UUID(), in: presets)
        #expect(!fallback.requiresAI)
        #expect(fallback.name == DictationPreset.plain.name)
    }

    @Test func appleIntelligenceReasonsArePlain() {
        #expect(AppleIntelligenceStatus.available.isAvailable)
        #expect(AppleIntelligenceStatus.available.note == nil)
        #expect(AppleIntelligenceStatus.unavailable(.deviceNotEligible).note == "This Mac does not support Apple Intelligence.")
        #expect(AppleIntelligenceStatus.unavailable(.notEnabled).note == "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri.")
        #expect(AppleIntelligenceStatus.unavailable(.modelNotReady).note == "Apple Intelligence is still downloading.")
        #expect(AppleIntelligenceStatus.unavailable(.needsMacOS26).note == "Needs macOS 26 or later.")
        #expect(!AppleIntelligenceStatus.unavailable(.other).isAvailable)
    }

    @Test func providerNotesSayWhereTextGoes() {
        #expect(AIProviderPane.providerNote(.appleIntelligence) == "Your text stays on your Mac.")
        #expect(AIProviderPane.providerNote(.ollama) == "Your text stays on your Mac or in your network.")
        #expect(AIProviderPane.providerNote(.claude) == "Your text is sent to Claude.")
        #expect(AIProviderPane.providerNote(.openai) == "Your text is sent to OpenAI.")
    }
}
