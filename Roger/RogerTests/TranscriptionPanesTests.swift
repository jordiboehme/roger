import CoreAudio
import Foundation
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
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligenceAvailable: true) == "Apple Intelligence (local)")
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligenceAvailable: false) == "Apple Intelligence (macOS 26 or later)")
        #expect(AIProviderPane.menuTitle(.ollama, appleIntelligenceAvailable: true) == "Ollama (local)")
        #expect(AIProviderPane.menuTitle(.claude, appleIntelligenceAvailable: true) == "Claude (cloud)")
        #expect(AIProviderPane.menuTitle(.openai, appleIntelligenceAvailable: false) == "OpenAI (cloud)")
    }

    @Test func filesOutputNoteNamesTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/Lib/Transcripts", isDirectory: true)
        #expect(FilesPane.outputNote(.library, transcriptsFolder: folder) == "/tmp/Lib/Transcripts/YYYY/MM")
        #expect(FilesPane.outputNote(.alongsideSource, transcriptsFolder: folder)
            == "In the folder of the dropped file, as <file name>.md.")
    }

    /// The checkmark sits on the preset in use: a deleted or AI preset falls
    /// back to Plain, like `AppState.fileTranscriptionPreset`.
    @Test func localPresetMenuChecksThePresetInUse() {
        let presets = DictationPreset.builtInPresets
        let local = presets.first { !$0.requiresAI && $0.id != DictationPreset.plain.id }!
        let ai = presets.first { $0.requiresAI }!
        #expect(LocalPresetMenu.effectiveID(selection: local.id, presets: presets) == local.id)
        #expect(LocalPresetMenu.effectiveID(selection: ai.id, presets: presets) == DictationPreset.plain.id)
        #expect(LocalPresetMenu.effectiveID(selection: UUID(), presets: presets) == DictationPreset.plain.id)
    }
}
