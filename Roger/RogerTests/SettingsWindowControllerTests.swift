import AppKit
import SwiftUI
import Testing
@testable import Roger

@MainActor
struct SettingsWindowControllerTests {
    final class Log {
        var policies: [NSApplication.ActivationPolicy] = []
        var presented = 0
    }

    private func make(_ log: Log) -> SettingsWindowController {
        let presence = AppWindowPresence { log.policies.append($0) }
        return SettingsWindowController(
            presence: presence,
            memory: .none,
            frameAutosaveName: nil,
            present: { _ in log.presented += 1 },
            makeContent: { _ in AnyView(EmptyView()) }
        )
    }

    @Test func showSelectsThePaneAndReusesTheWindow() throws {
        let log = Log()
        let controller = make(log)
        controller.show(.presets)
        let first = try #require(controller.window)
        #expect(controller.navigation.selection == .presets)
        #expect(controller.isOpen)

        controller.show(.microphone)
        #expect(controller.window === first)
        #expect(controller.navigation.selection == .microphone)
        #expect(log.presented == 2)
        #expect(log.policies == [.regular])
    }

    @Test func showWithoutAPaneKeepsTheSelection() {
        let log = Log()
        let controller = make(log)
        controller.show(.agents)
        controller.show()
        #expect(controller.navigation.selection == .agents)
    }

    @Test func closingLeavesThePresenceAndReopenReusesTheWindow() throws {
        let log = Log()
        let controller = make(log)
        controller.show(.files)
        let window = try #require(controller.window)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(!controller.isOpen)
        #expect(log.policies == [.regular, .accessory])

        controller.show()
        #expect(controller.window === window)
        #expect(controller.navigation.selection == .files)
        #expect(log.policies == [.regular, .accessory, .regular])
    }

    @Test func anotherWindowClosingIsIgnored() {
        let log = Log()
        let controller = make(log)
        controller.show(.general)
        let other = NSWindow()
        other.isReleasedWhenClosed = false
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: other))
        #expect(controller.isOpen)
        #expect(log.policies == [.regular])
    }

    @Test func theWindowHasTheSpecSizes() throws {
        let controller = make(Log())
        controller.show()
        let window = try #require(controller.window)
        #expect(window.contentMinSize == NSSize(width: 640, height: 460))
        #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 720, height: 540))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
    }
}

/// Closing the settings window must end the pane (onDisappear saves an API
/// key, timers stop) and reopening must start it again (.task and onAppear
/// run). Uses a real NSWindow and NSHostingController, never on screen.
@MainActor
struct SettingsPaneLifecycleTests {
    final class Events {
        var list: [String] = []
    }

    struct Probe: View {
        let events: Events
        var body: some View {
            Color.clear
                .onAppear { events.list.append("appear") }
                .onDisappear { events.list.append("disappear") }
        }
    }

    private func make(_ events: Events) -> SettingsWindowController {
        SettingsWindowController(
            presence: AppWindowPresence { _ in },
            memory: .none,
            frameAutosaveName: nil,
            present: { $0.contentView?.layoutSubtreeIfNeeded() },
            makeContent: { navigation in
                AnyView(SettingsWhileVisible(navigation: navigation) { Probe(events: events) })
            }
        )
    }

    private func close(_ controller: SettingsWindowController) throws {
        let window = try #require(controller.window)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    @Test func closeEndsThePaneAndReopenStartsItAgain() throws {
        let events = Events()
        let controller = make(events)
        controller.show(.aiProvider)
        #expect(controller.navigation.isVisible)
        #expect(events.list == ["appear"])

        try close(controller)
        #expect(!controller.navigation.isVisible)
        #expect(events.list == ["appear", "disappear"])

        controller.show()
        #expect(events.list == ["appear", "disappear", "appear"])
    }

    @Test func closeForTerminationEndsThePaneThroughWindowWillClose() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let events = Events()
        let controller = SettingsWindowController(
            presence: AppWindowPresence { policies.append($0) },
            memory: .none,
            frameAutosaveName: nil,
            present: { $0.contentView?.layoutSubtreeIfNeeded() },
            makeContent: { navigation in
                AnyView(SettingsWhileVisible(navigation: navigation) { Probe(events: events) })
            }
        )
        controller.show(.aiProvider)
        controller.closeForTermination()
        #expect(events.list == ["appear", "disappear"])
        #expect(!controller.isOpen)
        #expect(!controller.navigation.isVisible)
        #expect(policies == [.regular, .accessory])

        // A second call, or one with the window already closed, does nothing.
        controller.closeForTermination()
        #expect(events.list == ["appear", "disappear"])
        #expect(policies == [.regular, .accessory])
    }

    @Test func closeForTerminationWithoutAWindowDoesNothing() {
        let controller = make(Events())
        controller.closeForTermination()
        #expect(controller.window == nil)
        #expect(!controller.isOpen)
    }

    @Test func closeEndsEditingInTheWindow() throws {
        let controller = make(Events())
        controller.show()
        let window = try #require(controller.window)
        let field = NSTextField()
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        try close(controller)
        #expect(window.firstResponder === window)
    }
}
