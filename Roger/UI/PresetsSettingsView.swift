import SwiftUI

struct PresetsSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedPresetID: UUID?

    var body: some View {
        HSplitView {
            presetList
                .frame(minWidth: 150, maxWidth: 180)

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
                HStack {
                    if preset.isBuiltIn {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(preset.name)
                    Spacer()
                    if preset.id == coordinator.appState.activePresetID {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
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
                        Text("Built-in presets are read-only.")
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

            Section("Pipeline Steps") {
                Toggle("Remove filler words", isOn: preset.enableFillerRemoval)
                Toggle("Remove repeated words", isOn: preset.enableDedup)
                Toggle("AI punctuation & formatting", isOn: preset.enableAIFormatting)
                Toggle("Apply custom dictionary", isOn: preset.enableCustomDictionary)
                Toggle("AI rewrite", isOn: preset.enableRewrite)
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
        }
        .formStyle(.grouped)
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
            dictionaryEntries: source.dictionaryEntries
        )
        coordinator.appState.presets.append(newPreset)
        selectedPresetID = newPreset.id
    }

    private func removeSelectedPreset() {
        guard let id = selectedPresetID, !selectedPresetIsBuiltIn else { return }
        coordinator.appState.presets.removeAll { $0.id == id }
        if coordinator.appState.activePresetID == id {
            coordinator.appState.activePresetID = DictationPreset.defaultPresetID
        }
        selectedPresetID = coordinator.appState.activePresetID
    }
}
