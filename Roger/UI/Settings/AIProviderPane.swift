import SwiftUI

/// Settings > Text Model: which AI formats and rewrites text, and its
/// settings. API keys stay in the keychain.
struct AIProviderPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var claudeKey: String = KeychainManager.loadAPIKey(for: .claude) ?? ""
    @State private var openAIKey: String = KeychainManager.loadAPIKey(for: .openai) ?? ""
    @State private var testingConnection = false
    @State private var connectionStatus: String?

    private static var isAppleIntelligenceAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        @Bindable var state = coordinator.appState
        let provider = state.selectedLLMProvider
        SettingsForm {
            Section {
                Picker(selection: $state.selectedLLMProvider) {
                    ForEach(LLMProviderType.allCases) { choice in
                        Text(Self.menuTitle(choice, appleIntelligenceAvailable: Self.isAppleIntelligenceAvailable))
                            .tag(choice)
                    }
                } label: {
                    SettingsLabel(
                        title: "Provider",
                        note: provider.isLocal ? "Your text stays on your Mac or in your network." : "Your text is sent to \(provider.displayName)."
                    )
                }
            } header: {
                Text("Provider")
            } footer: {
                if !provider.isLocal {
                    Label("Dictated text is sent to the servers of \(provider.displayName) for processing.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            switch provider {
            case .appleIntelligence:
                Section("Apple Intelligence") {
                    SettingsRow(title: "Availability", note: "Needs macOS 26 with Apple Intelligence turned on. Your text never leaves your Mac.") {
                        SettingsStatus(
                            level: Self.isAppleIntelligenceAvailable ? .good : .bad,
                            text: Self.isAppleIntelligenceAvailable ? "Available" : "Needs macOS 26"
                        )
                    }
                }
            case .ollama:
                Section {
                    TextField("Base URL", text: $state.ollamaBaseURL)
                    TextField("Model", text: $state.ollamaModel)
                    SettingsRow(
                        title: "Connection",
                        note: connectionStatus,
                        noteColor: SettingsResultColor.color(for: connectionStatus)
                    ) {
                        HStack {
                            if testingConnection {
                                ProgressView().controlSize(.small)
                            }
                            Button("Test Connection") { testOllamaConnection() }
                                .disabled(testingConnection)
                        }
                    }
                } header: {
                    Text("Ollama")
                } footer: {
                    Text("Ollama runs on your Mac or on another computer in your network. Your text stays there.")
                }
            case .claude:
                Section {
                    SecureField("API key", text: $claudeKey)
                        .onChange(of: claudeKey) { _, newValue in saveKey(newValue, for: .claude) }
                    TextField("Model", text: $state.claudeModel)
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Roger keeps the key in your keychain.")
                }
            case .openai:
                Section {
                    SecureField("API key", text: $openAIKey)
                        .onChange(of: openAIKey) { _, newValue in saveKey(newValue, for: .openai) }
                    TextField("Model", text: $state.openAIModel)
                } header: {
                    Text("OpenAI")
                } footer: {
                    Text("Roger keeps the key in your keychain.")
                }
            }
        }
    }

    /// Menu entry: the provider name and where the text goes.
    static func menuTitle(_ provider: LLMProviderType, appleIntelligenceAvailable: Bool) -> String {
        if provider == .appleIntelligence && !appleIntelligenceAvailable {
            return "\(provider.displayName) (macOS 26 or later)"
        }
        return "\(provider.displayName) (\(provider.isLocal ? "local" : "cloud"))"
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
            connectionStatus = available ? "OK: connected" : "Cannot reach Ollama"
        }
    }
}
