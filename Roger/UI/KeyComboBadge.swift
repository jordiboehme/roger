import SwiftUI

/// Compact capsule showing the Caps Lock glyph and, optionally, a modifier
/// key glyph. Used in the menu bar cheat sheet and the Presets list to
/// advertise which key combo triggers a preset.
struct KeyComboBadge: View {
    let modifier: CapsModifier?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "capslock")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            if let modifier {
                Text("+")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Image(systemName: symbolName(for: modifier))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    private func symbolName(for modifier: CapsModifier) -> String {
        switch modifier {
        case .shift: return "shift"
        case .option: return "option"
        case .control: return "control"
        case .command: return "command"
        }
    }
}
