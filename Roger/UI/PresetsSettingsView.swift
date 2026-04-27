import SwiftUI

struct PresetsSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedPresetID: UUID?

    var body: some View {
        HSplitView {
            presetList
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)

            if let selectedID = selectedPresetID,
               let index = coordinator.appState.presets.firstIndex(where: { $0.id == selectedID }) {
                @Bindable var state = coordinator.appState
                presetDetail(preset: $state.presets[index])
            } else {
                Text("Select a preset")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            selectedPresetID = coordinator.appState.activePresetID
        }
    }

    // MARK: - Preset List

    private var presetList: some View {
        VStack(spacing: 0) {
            List(coordinator.appState.presets, id: \.id, selection: $selectedPresetID) { preset in
                HStack(spacing: 6) {
                    if preset.isBuiltIn {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(preset.name)
                    Spacer()
                    if preset.excludedFromRotation {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Hidden from Caps Lock + ←/→ rotation")
                    }
                    if preset.id == coordinator.appState.activePresetID {
                        KeyComboBadge(modifier: nil)
                    } else if let modifier = coordinator.appState.modifier(for: preset.id) {
                        KeyComboBadge(modifier: modifier)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    presetContextMenu(for: preset)
                }
                .tag(preset.id)
            }

            Divider()

            HStack(spacing: 4) {
                toolbarButton("plus", action: addCustomPreset)
                toolbarButton("minus", action: removeSelectedPreset)
                    .disabled(selectedPresetIsBuiltIn)
                toolbarButton("doc.on.doc", action: duplicateSelectedPreset)
                    .disabled(selectedPresetID == nil)
                    .help("Duplicate preset")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Preset Detail

    private func presetDetail(preset: Binding<DictationPreset>) -> some View {
        Form {
            if preset.wrappedValue.isBuiltIn {
                Section {
                    HStack {
                        Text("Built-in presets are read-only — language and output settings can still be customized.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Duplicate to Edit") {
                            duplicatePreset(preset.wrappedValue)
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Name") {
                TextField("Preset name", text: preset.name)
                    .disabled(preset.wrappedValue.isBuiltIn)
            }

            Section {
                Toggle("Remove filler words", isOn: preset.enableFillerRemoval)
                Toggle("Remove repeated words", isOn: preset.enableDedup)
                Toggle("Apply custom dictionary", isOn: preset.enableCustomDictionary)
            } header: {
                Text("Text Cleanup")
            } footer: {
                Text("Deterministic, offline steps applied to the raw transcription.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .disabled(preset.wrappedValue.isBuiltIn)

            Section {
                Toggle("Punctuation & formatting", isOn: preset.enableAIFormatting)
                Toggle("Rewrite", isOn: preset.enableRewrite)
            } header: {
                Text("AI Processing")
            } footer: {
                Text("Runs through the AI provider configured in Settings › AI Provider.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .disabled(preset.wrappedValue.isBuiltIn)

            if preset.wrappedValue.enableAIFormatting {
                Section("Formatting Prompt") {
                    TextEditor(text: preset.aiPrompt)
                        .font(.callout)
                        .frame(minHeight: 60)
                        .disabled(preset.wrappedValue.isBuiltIn)
                }
            }

            if preset.wrappedValue.enableRewrite {
                Section("Rewrite Prompt") {
                    TextEditor(text: preset.rewritePrompt)
                        .font(.callout)
                        .frame(minHeight: 60)
                        .disabled(preset.wrappedValue.isBuiltIn)
                }
            }

            if preset.wrappedValue.enableCustomDictionary {
                dictionarySection(preset: preset)
            }

            languageSection(preset: preset)

            Section {
                Picker("Append at end", selection: preset.trailingCharacter) {
                    ForEach(TrailingCharacter.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Toggle("Press Return after insertion", isOn: preset.sendReturnAfterInsert)
            } header: {
                Text("Output")
            } footer: {
                Text("Use Return to submit the text automatically — handy for sending a prompt to a chat box or chat app.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Language Section

    @ViewBuilder
    private func languageSection(preset: Binding<DictationPreset>) -> some View {
        let pinnedCode = preset.wrappedValue.language
        let isEnglishOnly = coordinator.appState.transcriptionMode == .englishOnly
        let aiUnsupported = pinnedCode.map { code in
            preset.wrappedValue.requiresAI
                && coordinator.appState.selectedLLMProvider == .appleIntelligence
                && !AppleIntelligenceLanguageSupport.supports(languageCode: code)
        } ?? false

        Section {
            Picker("Language", selection: preset.language) {
                Text("Automatic").tag(String?.none)
                ForEach(WhisperLanguage.all, id: \.code) { entry in
                    Text(entry.displayName).tag(Optional(entry.code))
                }
            }
            .pickerStyle(.menu)

            if pinnedCode != nil && isEnglishOnly {
                warningRow(
                    "The active model is English-only — this language setting will be ignored. Switch to a multilingual model in General settings."
                )
            }

            if aiUnsupported, let code = pinnedCode {
                warningRow(
                    "Apple Intelligence doesn't support \(WhisperLanguage.displayName(for: code)) — the AI step in this preset will fail. Switch AI provider in Settings › AI Provider, or pick a different language."
                )
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Pin a language to skip Whisper's auto-detection and avoid short utterances being misheard as the wrong language.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Dictionary Editor

    private func dictionarySection(preset: Binding<DictationPreset>) -> some View {
        Section("Custom Dictionary") {
            ForEach(preset.dictionaryEntries) { $entry in
                HStack {
                    TextField("Find", text: $entry.find)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    TextField("Replace", text: $entry.replace)
                        .textFieldStyle(.roundedBorder)
                    Button(action: {
                        preset.wrappedValue.dictionaryEntries.removeAll { $0.id == entry.id }
                    }) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Add Entry") {
                preset.wrappedValue.dictionaryEntries.append(
                    DictionaryEntry(find: "", replace: "")
                )
            }
            .disabled(preset.wrappedValue.isBuiltIn)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func presetContextMenu(for preset: DictationPreset) -> some View {
        let isMain = preset.id == coordinator.appState.activePresetID
        let currentModifier = coordinator.appState.modifier(for: preset.id)

        Button {
            coordinator.appState.activePresetID = preset.id
            coordinator.appState.clearBinding(for: preset.id)
        } label: {
            Label("Set as main preset", systemImage: isMain ? "checkmark" : "")
        }

        Divider()

        Button {
            coordinator.appState.clearBinding(for: preset.id)
        } label: {
            Label("No modifier", systemImage: !isMain && currentModifier == nil ? "checkmark" : "")
        }
        .disabled(isMain)

        ForEach(CapsModifier.allCases) { modifier in
            Button {
                coordinator.appState.bindModifier(modifier, to: preset.id)
            } label: {
                Label("\(modifier.symbol) \(modifier.displayName)", systemImage: currentModifier == modifier ? "checkmark" : "")
            }
            .disabled(isMain)
        }

        Divider()

        Button {
            toggleExcludeFromRotation(preset.id)
        } label: {
            Label(
                preset.excludedFromRotation ? "Show in rotation" : "Hide from rotation",
                systemImage: preset.excludedFromRotation ? "eye" : "eye.slash"
            )
        }
    }

    private func toggleExcludeFromRotation(_ presetID: UUID) {
        guard let index = coordinator.appState.presets.firstIndex(where: { $0.id == presetID }) else { return }
        coordinator.appState.presets[index].excludedFromRotation.toggle()
    }

    // MARK: - Components

    private func toolbarButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var selectedPresetIsBuiltIn: Bool {
        guard let id = selectedPresetID else { return true }
        return coordinator.appState.presets.first { $0.id == id }?.isBuiltIn ?? true
    }

    private func addCustomPreset() {
        let newPreset = DictationPreset(
            id: UUID(),
            name: "Custom",
            isBuiltIn: false,
            enableFillerRemoval: true,
            enableDedup: true,
            enableAIFormatting: true,
            enableCustomDictionary: false,
            enableRewrite: false,
            aiPrompt: "Add proper punctuation and capitalization to this dictated text. Return only the corrected text, nothing else.",
            rewritePrompt: "",
            dictionaryEntries: []
        )
        coordinator.appState.presets.append(newPreset)
        selectedPresetID = newPreset.id
    }

    private func duplicateSelectedPreset() {
        guard let id = selectedPresetID,
              let preset = coordinator.appState.presets.first(where: { $0.id == id })
        else { return }
        duplicatePreset(preset)
    }

    private func duplicatePreset(_ source: DictationPreset) {
        let newPreset = DictationPreset(
            id: UUID(),
            name: "\(source.name) Copy",
            isBuiltIn: false,
            enableFillerRemoval: source.enableFillerRemoval,
            enableDedup: source.enableDedup,
            enableAIFormatting: source.enableAIFormatting,
            enableCustomDictionary: source.enableCustomDictionary,
            enableRewrite: source.enableRewrite,
            aiPrompt: source.aiPrompt,
            rewritePrompt: source.rewritePrompt,
            dictionaryEntries: source.dictionaryEntries,
            trailingCharacter: source.trailingCharacter,
            sendReturnAfterInsert: source.sendReturnAfterInsert,
            excludedFromRotation: source.excludedFromRotation,
            language: source.language
        )
        coordinator.appState.presets.append(newPreset)
        selectedPresetID = newPreset.id
    }

    private func removeSelectedPreset() {
        guard let id = selectedPresetID, !selectedPresetIsBuiltIn else { return }
        coordinator.appState.removePreset(id: id)
        selectedPresetID = coordinator.appState.activePresetID
    }
}
