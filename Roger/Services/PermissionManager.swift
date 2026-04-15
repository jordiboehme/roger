import AppKit
import AVFoundation
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Permissions")

@MainActor
@Observable
final class PermissionManager {
    var microphoneAuthorized = false
    var accessibilityAuthorized = false

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        checkMicrophone()
        checkAccessibility()
    }

    // MARK: - Microphone

    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
        case .notDetermined:
            microphoneAuthorized = false
        default:
            microphoneAuthorized = false
        }
    }

    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneAuthorized = granted
        if granted {
            logger.info("Microphone permission granted")
        } else {
            logger.warning("Microphone permission denied")
        }
        return granted
    }

    // MARK: - Accessibility

    func checkAccessibility() {
        accessibilityAuthorized = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityAuthorized = trusted
        if trusted {
            logger.info("Accessibility permission granted")
        } else {
            logger.info("Accessibility permission prompt shown")
        }
    }

    /// Opens System Settings to the Accessibility privacy pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
