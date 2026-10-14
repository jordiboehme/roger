import SwiftUI

/// Settings > Presets: the preset list on the leading side, the selected
/// preset on the trailing side.
struct PresetsPane: View {
    /// The only fixed width in a pane (spec).
    static let listWidth: CGFloat = 180

    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedPresetID: UUID?
    @State private var pendingDelete: DictationPreset?
    @State private var pendingReset: DictationPreset?

    var body: some View {
        HStack(spacing: 0) {
            presetList
                .frame(width: Self.listWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedPresetID == nil {
                selectedPresetID = coordinator.appState.activePresetID
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.displayName ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { preset in
            Button("Delete", role: .destructive) { delete(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You cannot undo this.")
        }
        .confirmationDialog(
            "Reset \"\(pendingReset?.displayName ?? "")\"?",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            presenting: pendingReset
        ) { preset in
            Button("Reset", role: .destructive) { reset(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The preset gets its original steps, prompts and settings back. Your changes and dictionary words in it are lost.")
        }
    }

    // MARK: - List

    private var presetList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedPresetID) {
                Section("Built-in") {
                    rows(coordinator.appState.presets.filter(\.isBuiltIn))
                }
                let custom = coordinator.appState.presets.filter { !$0.isBuiltIn }
                if !custom.isEmpty {
                    Section("Custom") {
                        rows(custom)
                    }
                }
            }
            Divider()
            Button {
                addPreset()
            } label: {
                Label("New Preset", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rows(_ presets: [DictationPreset]) -> some View {
        ForEach(presets) { preset in
            PresetListRow(
                preset: preset,
                isMain: preset.id == coordinator.appState.activePresetID,
                modifier: coordinator.appState.modifier(for: preset.id)
            )
            .tag(preset.id)
            .contextMenu { contextMenu(for: preset) }
        }
    }

    /// A menu item with a checkmark when it is the current choice. No
    /// empty symbol name, so macOS logs nothing.
    @ViewBuilder
    private func checkLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func contextMenu(for preset: DictationPreset) -> some View {
        let state = coordinator.appState
        let isMain = preset.id == state.activePresetID
        let currentModifier = state.modifier(for: preset.id)

        Button {
            state.activePresetID = preset.id
            state.clearBinding(for: preset.id)
        } label: {
            checkLabel("Set as main preset", checked: isMain)
        }

        Divider()

        Button {
            state.clearBinding(for: preset.id)
        } label: {
            checkLabel("No modifier", checked: !isMain && currentModifier == nil)
        }
        .disabled(isMain)

        ForEach(CapsModifier.allCases) { modifier in
            Button {
                state.bindModifier(modifier, to: preset.id)
            } label: {
                checkLabel("\(modifier.symbol) \(modifier.displayName)", checked: currentModifier == modifier)
            }
            .disabled(isMain)
        }

        Divider()

        Button {
            toggleRotation(preset.id)
        } label: {
            Label(
                preset.excludedFromRotation ? "Show in rotation" : "Hide from rotation",
                systemImage: preset.excludedFromRotation ? "eye" : "eye.slash"
            )
        }

        Divider()

        Button("Duplicate") { duplicate(preset) }
        if preset.isBuiltIn {
            Button("Reset…") { pendingReset = preset }
                .disabled(!preset.isChangedBuiltIn)
        } else {
            Button("Delete…", role: .destructive) { pendingDelete = preset }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedPresetID, let preset = coordinator.appState.presets.first(where: { $0.id == id }) {
            PresetDetailForm(
                preset: binding(for: id, fallback: preset),
                provider: coordinator.appState.selectedLLMProvider,
                onReset: { pendingReset = preset },
                onDelete: { pendingDelete = preset }
            )
            // A new form per preset, so Advanced starts collapsed.
            .id(id)
        } else {
            ContentUnavailableView(
                "No Preset Selected",
                systemImage: "text.badge.star",
                description: Text("Select a preset or make a new one.")
            )
        }
    }

    /// Bound by id, not by index, so deleting a preset never writes into
    /// another one.
    private func binding(for id: UUID, fallback: DictationPreset) -> Binding<DictationPreset> {
        Binding(
            get: { coordinator.appState.presets.first { $0.id == id } ?? fallback },
            set: { newValue in
                guard let index = coordinator.appState.presets.firstIndex(where: { $0.id == id }) else { return }
                coordinator.appState.presets[index] = newValue
            }
        )
    }

    // MARK: - Actions

    private func addPreset() {
        let preset = DictationPreset.newCustom()
        coordinator.appState.presets.append(preset)
        selectedPresetID = preset.id
    }

    private func duplicate(_ preset: DictationPreset) {
        let copy = preset.duplicated()
        coordinator.appState.presets.append(copy)
        selectedPresetID = copy.id
    }

    private func delete(_ preset: DictationPreset) {
        guard !preset.isBuiltIn else { return }
        if selectedPresetID == preset.id {
            selectedPresetID = nil
        }
        coordinator.appState.removePreset(id: preset.id)
        if selectedPresetID == nil {
            selectedPresetID = coordinator.appState.activePresetID
        }
    }

    private func reset(_ preset: DictationPreset) {
        guard let index = coordinator.appState.presets.firstIndex(where: { $0.id == preset.id }) else { return }
        coordinator.appState.presets[index] = coordinator.appState.presets[index].resetToOriginal()
    }

    /// Apple Intelligence does not know every language Parakeet does.
    static func languageWarning(preset: DictationPreset, provider: LLMProviderType) -> String? {
        guard let code = preset.language,
              preset.requiresAI,
              provider == .appleIntelligence,
              !AppleIntelligenceLanguageSupport.supports(languageCode: code)
        else { return nil }
        return "Apple Intelligence does not support \(WhisperLanguage.displayName(for: code)). The AI steps of this preset will fail. Pick another text model or language."
    }

    private func toggleRotation(_ id: UUID) {
        guard let index = coordinator.appState.presets.firstIndex(where: { $0.id == id }) else { return }
        coordinator.appState.presets[index].excludedFromRotation.toggle()
    }
}

/// One row of the preset list: name, log and rotation marks, key badge.
/// The marks use the caption font, so every row has the height of the name.
private struct PresetListRow: View {
    let preset: DictationPreset
    let isMain: Bool
    let modifier: CapsModifier?

    var body: some View {
        HStack(spacing: 4) {
            Text(preset.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(preset.displayName)
            Spacer(minLength: 4)
            Group {
                if preset.output == .logEntry {
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                        .help("Saves to the log")
                }
                if preset.excludedFromRotation {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.tertiary)
                        .help("Not in the Caps Lock rotation")
                }
                if isMain {
                    PresetKeyBadge(modifier: nil)
                } else if let modifier {
                    PresetKeyBadge(modifier: modifier)
                }
            }
            .font(.caption)
        }
        .contentShape(Rectangle())
    }
}

/// The key of a preset as symbols, smaller than the popover's badge so the
/// row keeps the height of its name.
private struct PresetKeyBadge: View {
    let modifier: CapsModifier?

    var body: some View {
        HStack(spacing: 1) {
            if let modifier {
                Text(modifier.symbol)
            }
            Image(systemName: "capslock")
        }
        .foregroundStyle(.secondary)
        .help(modifier.map { "\($0.displayName) + Caps Lock" } ?? "Caps Lock (main preset)")
    }
}

/// The selected preset as a grouped form.
private struct PresetDetailForm: View {
    @Binding var preset: DictationPreset
    let provider: LLMProviderType
    let onReset: () -> Void
    let onDelete: () -> Void
    @State private var advancedExpanded = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        SettingsForm {
            Section("Preset") {
                TextField("Name", text: $preset.name, prompt: Text(DictationPreset.untitledName))
                    .focused($nameFocused)
                    .onSubmit(trimName)
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { trimName() }
                    }
                    // Switching to another preset ends editing too.
                    .onDisappear(perform: trimName)
                Picker(selection: $preset.language) {
                    Text("Automatic").tag(String?.none)
                    ForEach(WhisperLanguage.all, id: \.code) { entry in
                        Text(entry.displayName).tag(Optional(entry.code))
                    }
                } label: {
                    SettingsLabel(title: "Language", note: "Stops misheard short phrases.")
                }
                if let warning = PresetsPane.languageWarning(preset: preset, provider: provider) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Picker("Output", selection: $preset.output) {
                    ForEach(PresetOutput.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            }

            Section("Processing") {
                SettingsToggle(title: "Remove filler words", note: "Drops um, uh and similar words.", isOn: $preset.enableFillerRemoval)
                SettingsToggle(title: "Remove repeated words", note: "Drops a word you said twice in a row.", isOn: $preset.enableDedup)
                SettingsToggle(title: "AI formatting", note: "Uses your text model: \(provider.displayName).", isOn: $preset.enableAIFormatting)
                SettingsToggle(title: "AI rewrite", note: "Uses your text model: \(provider.displayName).", isOn: $preset.enableRewrite)
            }

            Section {
                if preset.output == .logEntry {
                    SettingsToggle(title: "Keep audio", note: "Also saves the recording as an .m4a file next to the entry.", isOn: $preset.keepAudio)
                } else {
                    Picker("Append at the end", selection: $preset.trailingCharacter) {
                        ForEach(TrailingCharacter.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    SettingsToggle(
                        title: "Press Return after inserting",
                        note: "Sends the text right away, for example in a chat box.",
                        isOn: $preset.sendReturnAfterInsert
                    )
                }
            } header: {
                Text("Output options")
            } footer: {
                if preset.output == .logEntry {
                    Text("Saves the text as a Markdown file in the Logs folder of your library. Nothing is typed.")
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    promptEditor("Formatting prompt", text: $preset.aiPrompt)
                    promptEditor("Rewrite prompt", text: $preset.rewritePrompt)
                    SettingsToggle(title: "Custom dictionary", note: preset.dictionarySummary, isOn: $preset.enableCustomDictionary)
                    if preset.enableCustomDictionary {
                        ForEach($preset.dictionaryEntries) { $entry in
                            HStack {
                                TextField("Find", text: $entry.find, prompt: Text("Find"))
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.tertiary)
                                TextField("Replace", text: $entry.replace, prompt: Text("Replace"))
                                Button {
                                    preset.dictionaryEntries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this word")
                            }
                            .labelsHidden()
                        }
                        Button("Add Word") {
                            preset.dictionaryEntries.append(DictionaryEntry(find: "", replace: ""))
                        }
                    }
                }
            }

            Section {
                if preset.isBuiltIn {
                    SettingsRow(title: "Original settings") {
                        Button("Reset…", action: onReset)
                            .disabled(!preset.isChangedBuiltIn)
                    }
                } else {
                    SettingsRow(title: "Delete this preset") {
                        Button("Delete…", role: .destructive, action: onDelete)
                    }
                }
            } footer: {
                if preset.isBuiltIn {
                    Text("Built-in presets can be changed. Reset brings back the original.")
                }
            }
        }
    }

    /// Trims the name when editing ends. Only writes when it changes.
    private func trimName() {
        let trimmed = preset.trimmedName
        if trimmed != preset.name {
            preset.name = trimmed
        }
    }

    private func promptEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.callout)
                .frame(minHeight: 60)
        }
    }
}
