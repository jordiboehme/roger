import Foundation
import Testing
@testable import Roger

struct SettingsFormatTests {
    let english = Locale(identifier: "en_US")

    @Test func secondsAndMinutes() {
        #expect(SettingsFormat.duration(1.5, locale: english) == "1.5 s")
        #expect(SettingsFormat.duration(2, locale: english) == "2 s")
        #expect(SettingsFormat.duration(0, locale: english) == "0 s")
        #expect(SettingsFormat.duration(30, locale: english) == "30 s")
        #expect(SettingsFormat.duration(60, locale: english) == "1 min")
        #expect(SettingsFormat.duration(90, locale: english) == "1 min 30 s")
        #expect(SettingsFormat.duration(600, locale: english) == "10 min")
    }

    @Test func germanUsesAComma() {
        #expect(SettingsFormat.duration(1.5, locale: Locale(identifier: "de_DE")) == "1,5 s")
    }
}

@MainActor
struct GeneralPaneTextTests {
    @Test func bannerNamesWhatIsMissing() {
        #expect(GeneralPane.missingPermissionsMessage(microphone: true, accessibility: true) == nil)
        #expect(GeneralPane.missingPermissionsMessage(microphone: false, accessibility: true)
            == "Roger needs access to the microphone to hear you.")
        #expect(GeneralPane.missingPermissionsMessage(microphone: true, accessibility: false)
            == "Roger needs Accessibility access to type your text and to see the dictation key.")
        #expect(GeneralPane.missingPermissionsMessage(microphone: false, accessibility: false)
            == "Roger needs access to the microphone and Accessibility access.")
    }

    @Test func dictationKeyFollowsTheRemap() {
        #expect(GeneralPane.dictationKey(capsLockActive: true) == "Caps Lock")
        #expect(GeneralPane.dictationKey(capsLockActive: false) == "F18")
        #expect(GeneralPane.dictationKey(capsLockActive: nil) == "Caps Lock or F18")
        #expect(GeneralPane.dictationNote(capsLockActive: false).contains("not set up"))
    }

    @Test func modesHaveShortTitlesAndNotes() {
        #expect(ActivationMode.allCases.map(\.title) == ["Push to talk", "Toggle"])
        for mode in ActivationMode.allCases {
            #expect(!mode.note.isEmpty)
        }
    }
}
