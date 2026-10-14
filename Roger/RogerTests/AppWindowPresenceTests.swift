import AppKit
import Testing
@testable import Roger

@MainActor
struct AppWindowPresenceTests {
    /// Records every policy change instead of touching NSApp.
    final class PolicyLog {
        var calls: [NSApplication.ActivationPolicy] = []
    }

    private func make() -> (AppWindowPresence, PolicyLog) {
        let log = PolicyLog()
        let presence = AppWindowPresence { log.calls.append($0) }
        return (presence, log)
    }

    @Test func firstWindowMakesRogerRegular() {
        let (presence, log) = make()
        presence.enter(.library)
        #expect(log.calls == [.regular])
        #expect(presence.isRegular)
    }

    @Test func libraryThenSettingsClosingLibraryFirst() {
        let (presence, log) = make()
        presence.enter(.library)
        presence.enter(.settings)
        #expect(log.calls == [.regular])
        presence.leave(.library)
        #expect(log.calls == [.regular])
        #expect(presence.isRegular)
        presence.leave(.settings)
        #expect(log.calls == [.regular, .accessory])
        #expect(!presence.isRegular)
    }

    @Test func libraryThenSettingsClosingSettingsFirst() {
        let (presence, log) = make()
        presence.enter(.library)
        presence.enter(.settings)
        presence.leave(.settings)
        #expect(log.calls == [.regular])
        presence.leave(.library)
        #expect(log.calls == [.regular, .accessory])
    }

    @Test func showingAnOpenWindowAgainCountsOnce() {
        let (presence, log) = make()
        presence.enter(.library)
        presence.enter(.library)
        presence.leave(.library)
        #expect(log.calls == [.regular, .accessory])
        #expect(presence.openWindows.isEmpty)
    }

    @Test func leaveWithoutEnterChangesNothing() {
        let (presence, log) = make()
        presence.leave(.settings)
        #expect(log.calls.isEmpty)
        presence.enter(.library)
        presence.leave(.settings)
        #expect(log.calls == [.regular])
    }

    @Test func openingAgainAfterTheLastCloseIsRegularAgain() {
        let (presence, log) = make()
        presence.enter(.settings)
        presence.leave(.settings)
        presence.enter(.settings)
        #expect(log.calls == [.regular, .accessory, .regular])
    }
}
