import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if case .error(let msg) = coordinator.appState.dictationState {
                alertBanner(msg, isRetryable: msg.contains("Model") || msg.contains("download")) {
                    coordinator.dismissError()
                    Task { await coordinator.setupModel() }
                } onDismiss: {
                    coordinator.dismissError()
                }
            }

            if !coordinator.hotkeyActive && coordinator.appState.dictationState == .idle {
                alertBanner("Hotkey not active — grant Accessibility in Settings", isRetryable: false, onRetry: {}, onDismiss: nil)
            }

            if coordinator.isSettingUpModel {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if let text = coordinator.appState.lastTranscription, !text.isEmpty {
                LastDictationCard(text: text)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            Divider().padding(.horizontal, 10)

            shortcutsSection
                .padding(.vertical, 8)

            Divider().padding(.horizontal, 10)

            VStack(spacing: 0) {
                SettingsLink {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Settings…")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    activateSettingsWindow()
                })

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "power")
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Quit Roger")
                            .font(.system(size: 13))
                        Spacer()
                        Text("over & out")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .task {
            coordinator.permissionManager.checkPermissions()
        }
    }

    // MARK: - Status

    private var statusHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.appState.statusText)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var statusSubtitle: String {
        let mode = coordinator.appState.transcriptionMode.displayName
        return coordinator.transcriptionEngine.isReady ? "\(mode) · Model loaded" : mode
    }

    // MARK: - Shortcuts cheat sheet

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Shortcuts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                SettingsLink {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    coordinator.appState.pendingSettingsTab = .presets
                    activateSettingsWindow()
                })
                .help("Edit presets")
            }
            .padding(.horizontal, 16)

            VStack(spacing: 2) {
                ForEach(Array(shortcutRows.enumerated()), id: \.offset) { _, row in
                    PresetCheatSheetRow(
                        preset: row.preset,
                        modifier: row.modifier,
                        isPrimary: row.modifier == nil
                    )
                }
            }
        }
    }

    private var shortcutRows: [(modifier: CapsModifier?, preset: DictationPreset)] {
        var rows: [(CapsModifier?, DictationPreset)] = [(nil, coordinator.appState.activePreset)]
        for modifier in CapsModifier.allCases {
            if let presetID = coordinator.appState.modifierBindings[modifier],
               let preset = coordinator.appState.presets.first(where: { $0.id == presetID }) {
                rows.append((modifier, preset))
            }
        }
        return rows
    }

    // MARK: - Alert banner

    private func alertBanner(_ message: String, isRetryable: Bool, onRetry: @escaping () -> Void, onDismiss: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if isRetryable {
                Button("Retry") { onRetry() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch coordinator.appState.dictationState {
        case .idle: .green
        case .listening: .red
        case .transcribing, .processing, .inserting: .orange
        case .error: .red
        }
    }

    private func dismissPopover() {
        if let panel = NSApp.keyWindow as? NSPanel {
            panel.close()
        }
    }

    private func activateSettingsWindow() {
        dismissPopover()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Last-dictation card

private struct LastDictationCard: View {
    let text: String
    @State private var isHovering = false
    @State private var justCopied = false

    var body: some View {
        Button(action: copy) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(isHovering ? 0.55 : 0.3))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            ZStack {
                if justCopied {
                    copiedBadge
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if isHovering {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
            .padding(6)
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: justCopied)
        .help("Click to copy")
    }

    private var copiedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
            Text("Copied")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor, in: Capsule())
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            justCopied = false
        }
    }
}

// MARK: - Cheat-sheet row

private struct PresetCheatSheetRow: View {
    let preset: DictationPreset
    let modifier: CapsModifier?
    let isPrimary: Bool

    var body: some View {
        HStack(spacing: 10) {
            KeyComboBadge(modifier: modifier)
            Text(preset.name)
                .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isPrimary ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .padding(.horizontal, 6)
    }
}

