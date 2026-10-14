import Testing
@testable import Roger

struct CapsLockRemapTests {
    static let realOutput = """
    RegistryID  Key                   Value
    1000009bb   UserKeyMapping   (
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    10000082d   UserKeyMapping   (
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    """

    @Test func findsTheMappingInRealOutput() {
        #expect(CapsLockRemap.isActive(hidutilOutput: Self.realOutput))
    }

    @Test func emptyMappingIsOff() {
        #expect(!CapsLockRemap.isActive(hidutilOutput: "RegistryID  Key  Value\n1000009bb   UserKeyMapping   (\n)\n"))
        #expect(!CapsLockRemap.isActive(hidutilOutput: "(null)"))
        #expect(!CapsLockRemap.isActive(hidutilOutput: ""))
    }

    @Test func otherMappingsDoNotCount() {
        let swapped = """
        (
            {
            HIDKeyboardModifierMappingDst = 30064771129;
            HIDKeyboardModifierMappingSrc = 30064771181;
        }
        )
        """
        #expect(!CapsLockRemap.isActive(hidutilOutput: swapped))
        let split = """
        (
            {
            HIDKeyboardModifierMappingDst = 30064771300;
            HIDKeyboardModifierMappingSrc = 30064771129;
        },
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771300;
        }
        )
        """
        #expect(!CapsLockRemap.isActive(hidutilOutput: split))
    }

    @Test func findsItAmongOtherMappingsAndInHex() {
        let mixed = """
        (
            {
            HIDKeyboardModifierMappingDst = 30064771300;
            HIDKeyboardModifierMappingSrc = 30064771299;
        },
            {
            HIDKeyboardModifierMappingSrc = 0x700000039;
            HIDKeyboardModifierMappingDst = 0x70000006D;
        }
        )
        """
        #expect(CapsLockRemap.isActive(hidutilOutput: mixed))
    }

    @Test func usagesMatchTheRemapCommand() {
        #expect(CapsLockRemap.capsLockUsage == 30_064_771_129)
        #expect(CapsLockRemap.f18Usage == 30_064_771_181)
    }
}
