import SwiftUI

/// Settings > Text Model: which AI formats and rewrites text, and its
/// settings. API keys stay in the keychain.
struct AIProviderPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var claudeKey: String = KeychainManager.loadAPIKey(for: .claude) ?? ""
    @State private var openAIKey: String = KeychainManager.loadAPIKey(for: .openai) ?? ""
    @State private var testingConnection = false
    @State private var connectionStatus: String?
    @State private var appleIntelligence = AppleIntelligenceStatus.current
    /// Set when the keychain refused a key.
    @State private var keyError: String?
    @FocusState private var focusedKey: LLMProviderType?

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
                        note: Self.providerNote(provider),
                        noteColor: provider.isLocal ? .secondary : .orange
                    )
                }
            } header: {
                Text("Provider")
            }

            switch provider {
            case .appleIntelligence:
                Section("Apple Intelligence") {
                    SettingsRow(title: "Availability", note: appleIntelligence.note) {
                        SettingsStatus(
                            level: appleIntelligence.isAvailable ? .good : .bad,
                            text: appleIntelligence.isAvailable ? "Available" : "Not available"
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
                        .focused($focusedKey, equals: .claude)
                        .onSubmit { saveKey(claudeKey, for: .claude) }
                        .onDisappear { saveKey(claudeKey, for: .claude) }
                    TextField("Model", text: $state.claudeModel)
                } header: {
                    Text("Claude")
                } footer: {
                    keyFooter
                }
            case .openai:
                Section {
                    SecureField("API key", text: $openAIKey)
                        .focused($focusedKey, equals: .openai)
                        .onSubmit { saveKey(openAIKey, for: .openai) }
                        .onDisappear { saveKey(openAIKey, for: .openai) }
                    TextField("Model", text: $state.openAIModel)
                } header: {
                    Text("OpenAI")
                } footer: {
                    keyFooter
                }
            }
        }
        .onChange(of: focusedKey) { old, _ in
            // The key field lost focus: save what was typed.
            switch old {
            case .claude: saveKey(claudeKey, for: .claude)
            case .openai: saveKey(openAIKey, for: .openai)
            default: break
            }
        }
        .onAppear { appleIntelligence = .current }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appleIntelligence = .current
        }
    }

    @ViewBuilder
    private var keyFooter: some View {
        if let keyError {
            Text(keyError).foregroundStyle(.red)
        } else {
            Text("Roger keeps the key in your keychain.")
        }
    }

    /// The note under the provider menu: where the text goes.
    static func providerNote(_ provider: LLMProviderType) -> String {
        switch provider {
        case .appleIntelligence: return "Your text stays on your Mac."
        case .ollama: return "Your text stays on your Mac or in your network."
        case .claude, .openai: return "Your text is sent to \(provider.displayName)."
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

    /// Writes the key when it differs from the stored one. An empty field
    /// removes the key.
    private func saveKey(_ key: String, for provider: LLMProviderType) {
        guard key != (KeychainManager.loadAPIKey(for: provider) ?? "") else { return }
        do {
            if key.isEmpty {
                try KeychainManager.deleteAPIKey(for: provider)
            } else {
                try KeychainManager.saveAPIKey(key, for: provider)
            }
            keyError = nil
        } catch {
            keyError = "Roger could not save the key: \(error.localizedDescription)"
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
