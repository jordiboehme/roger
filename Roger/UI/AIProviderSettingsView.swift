import SwiftUI

struct AIProviderSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var claudeKey: String = KeychainManager.loadAPIKey(for: .claude) ?? ""
    @State private var openAIKey: String = KeychainManager.loadAPIKey(for: .openai) ?? ""
    @State private var testingConnection = false
    @State private var connectionStatus: String?

    var body: some View {
        Form {
            providerPickerSection

            switch coordinator.appState.selectedLLMProvider {
            case .appleIntelligence:
                appleIntelligenceSection
            case .ollama:
                ollamaSection
            case .claude:
                claudeSection
            case .openai:
                openAISection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Provider Picker

    private var isAppleIntelligenceAvailable: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    private var providerPickerSection: some View {
        @Bindable var state = coordinator.appState
        return Section {
            Picker("Provider", selection: $state.selectedLLMProvider) {
                ForEach(LLMProviderType.allCases) { provider in
                    HStack(spacing: 6) {
                        Image(systemName: provider.icon)
                            .frame(width: 16)
                        Text(provider.displayName)
                        if provider == .appleIntelligence && !isAppleIntelligenceAvailable {
                            Text("macOS 26+")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if provider.isLocal {
                            Text("Local")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        } else {
                            Text("Cloud")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    .tag(provider)
                }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("AI Provider for Text Processing")
        } footer: {
            if !coordinator.appState.selectedLLMProvider.isLocal {
                Label(
                    "Dictated text will be sent to \(coordinator.appState.selectedLLMProvider.displayName) servers for processing.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Apple Intelligence

    private var appleIntelligenceSection: some View {
        Section("Apple Intelligence") {
            HStack {
                Image(systemName: "apple.intelligence")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-device processing")
                        .font(.caption.weight(.medium))
                    Text("Requires macOS 26 with Apple Intelligence enabled. Your audio and text never leave your Mac.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Ollama

    private var ollamaSection: some View {
        @Bindable var state = coordinator.appState
        return Section("Ollama") {
            TextField("Base URL", text: $state.ollamaBaseURL)
                .textFieldStyle(.roundedBorder)

            TextField("Model", text: $state.ollamaModel)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Test Connection") {
                    testOllamaConnection()
                }
                .disabled(testingConnection)

                if testingConnection {
                    ProgressView()
                        .controlSize(.small)
                }

                if let status = connectionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("OK") ? .green : .orange)
                }
            }

            Text("Ollama runs locally or on any machine on your network. Data stays within your trusted environment.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Claude

    private var claudeSection: some View {
        @Bindable var state = coordinator.appState
        return Section("Claude API") {
            SecureField("API Key", text: $claudeKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: claudeKey) { _, newValue in
                    saveKey(newValue, for: .claude)
                }

            TextField("Model", text: $state.claudeModel)
                .textFieldStyle(.roundedBorder)

            privacyWarning
        }
    }

    // MARK: - OpenAI

    private var openAISection: some View {
        @Bindable var state = coordinator.appState
        return Section("OpenAI API") {
            SecureField("API Key", text: $openAIKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: openAIKey) { _, newValue in
                    saveKey(newValue, for: .openai)
                }

            TextField("Model", text: $state.openAIModel)
                .textFieldStyle(.roundedBorder)

            privacyWarning
        }
    }

    private var privacyWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.open")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Dictated text will be sent to external servers for processing. Only use this provider if you're comfortable with that.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func saveKey(_ key: String, for provider: LLMProviderType) {
        if key.isEmpty {
            try? KeychainManager.deleteAPIKey(for: provider)
        } else {
            try? KeychainManager.saveAPIKey(key, for: provider)
        }
    }

    private func testOllamaConnection() {
        testingConnection = true
        connectionStatus = nil

        Task {
            let service = OllamaService(
                baseURL: coordinator.appState.ollamaBaseURL,
                model: coordinator.appState.ollamaModel
            )
            let available = await service.isAvailable
            testingConnection = false
            connectionStatus = available ? "OK — Connected" : "Cannot reach Ollama"
        }
    }
}
