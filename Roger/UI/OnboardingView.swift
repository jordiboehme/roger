import SwiftUI

struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                Text("Welcome to Roger")
                    .font(.title2.bold())
                Text("Speech-to-Text for macOS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            // Steps
            TabView(selection: $currentStep) {
                microphoneStep.tag(0)
                accessibilityStep.tag(1)
                capsLockStep.tag(2)
                modelStep.tag(3)
            }
            .tabViewStyle(.automatic)
            .frame(maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") { currentStep -= 1 }
                }
                Spacer()
                if currentStep < 3 {
                    Button("Next") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        coordinator.appState.hasCompletedOnboarding = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.appState.modelDownloadProgress != nil && coordinator.appState.modelDownloadProgress! < 1.0)
                }
            }
            .padding(16)
        }
        .frame(width: 460, height: 400)
    }

    // MARK: - Step 1: Microphone

    private var microphoneStep: some View {
        VStack(spacing: 16) {
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
            stepHeader(
                icon: "accessibility",
                title: "Accessibility Access",
                description: "Roger needs Accessibility permission to insert text at your cursor and listen for the global hotkey."
            )

            if coordinator.permissionManager.accessibilityAuthorized {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open Accessibility Settings") {
                    coordinator.permissionManager.requestAccessibility()
                }
                .buttonStyle(.bordered)

                Text("Add Roger in System Settings > Privacy & Security > Accessibility, then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

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
            stepHeader(
                icon: "capslock.fill",
                title: "Caps Lock Hotkey (Optional)",
                description: "Remap Caps Lock to act as a push-to-talk key. This remaps it system-wide — you can undo this anytime in Settings."
            )

            HStack(spacing: 12) {
                Button("Enable Caps Lock Remap") {
                    HotkeyManager.remapCapsLockToF18()
                    try? HotkeyManager.installRemapLaunchAgent()
                }
                .buttonStyle(.bordered)

                Button("Skip") {
                    currentStep += 1
                }
                .buttonStyle(.borderless)
            }

            Text("You can also use a custom keyboard shortcut instead — configure it in Settings > General.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 4: Model Download

    private var modelStep: some View {
        VStack(spacing: 16) {
            stepHeader(
                icon: "cpu",
                title: "Speech Recognition Model",
                description: "Roger uses an on-device model for speech recognition. The download is about 500 MB."
            )

            if coordinator.transcriptionEngine.isReady {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let progress = coordinator.appState.modelDownloadProgress {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text(progress < 1.0 ? "Downloading…" : "Setting up…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Download Model") {
                    Task { await coordinator.setupModel() }
                }
                .buttonStyle(.bordered)
            }

            if case .error(let msg) = coordinator.appState.dictationState {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Retry") {
                    coordinator.dismissError()
                    Task { await coordinator.setupModel() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
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
        }
    }
}
