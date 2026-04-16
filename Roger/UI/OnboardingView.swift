import SwiftUI

struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    var onComplete: (() -> Void)?
    @State private var currentStep = 0
    @State private var capsLockRemapped = false

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                Text("Welcome to Roger")
                    .font(.title2.bold())
                Text("Speech-to-Text for macOS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Step indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : step < currentStep ? .green : .secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        if step == currentStep {
                            Text(stepName(step))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.bottom, 12)

            Divider()

            // Step content
            Group {
                switch currentStep {
                case 0: microphoneStep
                case 1: accessibilityStep
                case 2: capsLockStep
                case 3: modelStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") { currentStep -= 1 }
                }
                Spacer()
                if currentStep < totalSteps - 1 {
                    Button("Next") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        coordinator.appState.hasCompletedOnboarding = true
                        onComplete?()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.transcriptionEngine.isReady)
                }
            }
            .padding(16)
        }
        .frame(width: 480, height: 460)
    }

    private func stepName(_ step: Int) -> String {
        switch step {
        case 0: "Microphone"
        case 1: "Accessibility"
        case 2: "Hotkey"
        case 3: "Model"
        default: ""
        }
    }

    // MARK: - Step 1: Microphone

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Spacer()
            stepHeader(
                icon: "mic.fill",
                title: "Microphone Access",
                description: "Roger needs access to your microphone to hear what you say."
            )

            if coordinator.permissionManager.microphoneAuthorized {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Microphone Access") {
                    Task { await coordinator.permissionManager.requestMicrophone() }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 2: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Spacer()
            stepHeader(
                icon: "accessibility",
                title: "Accessibility Access",
                description: "Required to insert text at your cursor and listen for the global hotkey."
            )

            if coordinator.permissionManager.accessibilityAuthorized {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open Accessibility Settings") {
                    coordinator.permissionManager.requestAccessibility()
                }
                .buttonStyle(.bordered)

                Text("Add Roger in System Settings > Privacy & Security > Accessibility, then click Check Again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                Button("Check Again") {
                    coordinator.permissionManager.checkAccessibility()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 3: Caps Lock

    private var capsLockStep: some View {
        VStack(spacing: 16) {
            Spacer()
            stepHeader(
                icon: "capslock.fill",
                title: "Caps Lock Hotkey",
                description: "Use Caps Lock as a push-to-talk key. This remaps it system-wide — you can undo it anytime in Settings."
            )

            if capsLockRemapped {
                Label("Caps Lock remapped to push-to-talk", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Enable Caps Lock Remap") {
                    let success = HotkeyManager.remapCapsLockToF18()
                    if success {
                        try? HotkeyManager.installRemapLaunchAgent()
                        capsLockRemapped = true
                    }
                }
                .buttonStyle(.bordered)
            }

            Text("Optional — you can also configure a different shortcut in Settings > General.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 4: Model Download

    private var modelStep: some View {
        VStack(spacing: 16) {
            Spacer()
            stepHeader(
                icon: "cpu",
                title: "Speech Recognition Model",
                description: "Roger uses an on-device model (~500 MB). Your voice data never leaves your Mac."
            )

            if coordinator.transcriptionEngine.isReady {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if coordinator.isSettingUpModel {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case .error(let msg) = coordinator.appState.dictationState {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                Button("Retry Download") {
                    coordinator.dismissError()
                    Task { await coordinator.setupModel() }
                }
                .buttonStyle(.bordered)
            } else {
                Button("Download Model") {
                    Task { await coordinator.setupModel() }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Helper

    private func stepHeader(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }
}
