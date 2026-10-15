import SwiftUI

/// "After saving" picker. Shows "Nothing", every command and, for an id
/// that no longer exists, "Missing command".
struct CommandPicker: View {
    let title: String
    let note: String?
    @Binding var selection: UUID?
    let commands: [AgentCommand]

    init(title: String, note: String?, selection: Binding<UUID?>, commands: [AgentCommand]) {
        self.title = title
        self.note = note
        self._selection = selection
        self.commands = commands
    }

    nonisolated static func options(selection: UUID?, commands: [AgentCommand]) -> [(id: UUID?, label: String)] {
        var result: [(id: UUID?, label: String)] = [(nil, "Nothing")]
        result += commands.map { (Optional($0.id), $0.displayName) }
        if let selection, !commands.contains(where: { $0.id == selection }) {
            result.append((selection, "Missing command"))
        }
        return result
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Self.options(selection: selection, commands: commands), id: \.id) { option in
                Text(option.label).tag(option.id)
            }
        } label: {
            SettingsLabel(title: title, note: note)
        }
    }
}
