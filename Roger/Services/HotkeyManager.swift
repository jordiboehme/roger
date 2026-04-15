import Carbon
import Cocoa
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "HotkeyManager")

final class HotkeyManager: @unchecked Sendable {
    var onRecordingStarted: (@Sendable () -> Void)?
    var onRecordingStopped: (@Sendable () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRecording = false
    private var activationMode: ActivationMode = .pushToTalk

    /// Virtual key code to listen for.
    /// Default: F18 (0x4F / 79) — Caps Lock remapped via hidutil.
    var triggerKeyCode: CGKeyCode = 79 // F18

    deinit {
        stop()
    }

    func start(mode: ActivationMode) {
        activationMode = mode
        setupEventTap()
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRecording = false
    }

    // MARK: - Caps Lock Remap

    /// Remaps Caps Lock to F18 via hidutil for the current session.
    @discardableResult
    static func remapCapsLockToF18() -> Bool {
        // Caps Lock = 0x700000039, F18 = 0x70000006D
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = [
            "property", "--set",
            #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
        ]

        do {
            try task.run()
            task.waitUntilExit()
            let success = task.terminationStatus == 0
            if success {
                logger.info("Caps Lock remapped to F18 via hidutil")
            }
            return success
        } catch {
            logger.error("hidutil remap failed: \(error)")
            return false
        }
    }

    /// Installs a LaunchAgent to persist the Caps Lock → F18 remap across reboots.
    static func installRemapLaunchAgent() throws {
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.jordiboehme.roger.capslock-remap</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/hidutil</string>
                <string>property</string>
                <string>--set</string>
                <string>{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

        let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)

        let plistURL = launchAgentDir.appendingPathComponent("com.jordiboehme.roger.capslock-remap.plist")
        try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        logger.info("Caps Lock remap LaunchAgent installed at \(plistURL.path)")
    }

    /// Removes the Caps Lock → F18 remap and its LaunchAgent.
    static func removeRemapLaunchAgent() {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.jordiboehme.roger.capslock-remap.plist")
        try? FileManager.default.removeItem(at: plistURL)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = ["property", "--set", #"{"UserKeyMapping":[]}"#]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Event Tap

    private func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passRetained(event)
            }

            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == manager.triggerKeyCode else {
                return Unmanaged.passRetained(event)
            }

            let isKeyDown = type == .keyDown

            switch manager.activationMode {
            case .pushToTalk:
                if isKeyDown && !manager.isRecording {
                    manager.isRecording = true
                    manager.onRecordingStarted?()
                } else if !isKeyDown && manager.isRecording {
                    manager.isRecording = false
                    manager.onRecordingStopped?()
                }
            case .toggle:
                if isKeyDown {
                    if manager.isRecording {
                        manager.isRecording = false
                        manager.onRecordingStopped?()
                    } else {
                        manager.isRecording = true
                        manager.onRecordingStarted?()
                    }
                }
            }

            // Consume the event so it doesn't propagate
            return nil
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            logger.error("Failed to create event tap — Accessibility permission required")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        logger.info("Event tap active, listening for keyCode \(self.triggerKeyCode)")
    }
}
