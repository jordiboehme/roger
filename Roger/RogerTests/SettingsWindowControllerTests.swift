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
