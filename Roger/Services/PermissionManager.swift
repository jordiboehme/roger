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

    /// Fires when accessibility flips from denied → granted at any checkpoint.
    /// Used by the coordinator to auto-start the hotkey listener without a
    /// manual "Retry Setup" click.
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?

    /// Fires when microphone flips from denied → granted at any checkpoint.
    @ObservationIgnored var onMicrophoneGranted: (() -> Void)?

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        checkMicrophone()
        checkAccessibility()
    }

    // MARK: - Microphone

    func checkMicrophone() {
        let wasAuthorized = microphoneAuthorized
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
        case .notDetermined:
            microphoneAuthorized = false
        default:
            microphoneAuthorized = false
        }
        if !wasAuthorized && microphoneAuthorized {
            logger.info("Microphone permission transitioned to granted")
            onMicrophoneGranted?()
        }
    }

    func requestMicrophone() async -> Bool {
        let wasAuthorized = microphoneAuthorized
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneAuthorized = granted
        if granted {
            logger.info("Microphone permission granted")
            if !wasAuthorized {
                onMicrophoneGranted?()
            }
        } else {
            logger.warning("Microphone permission denied")
        }
        return granted
    }

    // MARK: - Accessibility

    func checkAccessibility() {
        let wasAuthorized = accessibilityAuthorized
        accessibilityAuthorized = AXIsProcessTrusted()
        if !wasAuthorized && accessibilityAuthorized {
            logger.info("Accessibility permission transitioned to granted")
            onAccessibilityGranted?()
        }
    }

    func requestAccessibility() {
        let wasAuthorized = accessibilityAuthorized
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityAuthorized = trusted
        if trusted {
            logger.info("Accessibility permission granted")
            if !wasAuthorized {
                onAccessibilityGranted?()
            }
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
