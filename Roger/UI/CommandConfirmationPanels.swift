import AppKit
import Observation
import SwiftUI

/// The "Run <command>?" question of "Ask before running": a small floating
/// panel in the top right corner of the screen. It never activates Roger
/// and never becomes the key window, so the app the user types in keeps
/// the focus and dictation goes on. One panel per command; more panels
/// stack downwards.
@MainActor
final class CommandConfirmationPanels: CommandConfirming {
    private final class Question {
        let panel: NSPanel
        let model: CommandQuestionModel
        let continuation: CheckedContinuation<Bool, Never>

        init(panel: NSPanel, model: CommandQuestionModel, continuation: CheckedContinuation<Bool, Never>) {
            self.panel = panel
            self.model = model
            self.continuation = continuation
        }
    }

    static let width: CGFloat = 320
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 8

    private var questions: [UUID: Question] = [:]
    /// Oldest first, for the stacking order.
    private var order: [UUID] = []

    func confirm(commandID: UUID, commandName: String, itemTitle: String) async -> Bool {
        // The scheduler asks once per command; a second call replaces the first.
        answer(commandID, allowed: false)
        return await withCheckedContinuation { continuation in
            let model = CommandQuestionModel(commandName: commandName, itemTitle: itemTitle)
            let panel = Self.makePanel(model: model) { [weak self] allowed in
                self?.answer(commandID, allowed: allowed)
            }
            questions[commandID] = Question(panel: panel, model: model, continuation: continuation)
            order.append(commandID)
            layout()
            panel.orderFrontRegardless()
        }
    }

    func update(commandID: UUID, itemTitle: String) {
        questions[commandID]?.model.itemTitle = itemTitle
    }

    func dismiss(commandID: UUID) {
        answer(commandID, allowed: false)
    }

    /// Closes the panel and resumes its `confirm` exactly once.
    private func answer(_ commandID: UUID, allowed: Bool) {
        guard let question = questions.removeValue(forKey: commandID) else { return }
        order.removeAll { $0 == commandID }
        question.panel.orderOut(nil)
        question.continuation.resume(returning: allowed)
        layout()
    }

    /// Top right of the screen with the menu bar, oldest on top.
    private func layout() {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var top = visible.maxY - Self.margin
        for id in order {
            guard let panel = questions[id]?.panel else { continue }
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.margin - size.width, y: top - size.height))
            top -= size.height + Self.spacing
        }
    }

    private static func makePanel(model: CommandQuestionModel, onAnswer: @escaping (Bool) -> Void) -> NSPanel {
        let hosting = FirstClickHostingView(rootView: CommandQuestionView(model: model, onAnswer: onAnswer))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = QuestionPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.title = "Run \(model.commandName)?"
        panel.level = .floating
        // Roger is almost never the active app: a panel that hides on
        // deactivation would never be seen.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        return panel
    }
}

/// What the panel shows. The item changes when more triggers come in.
@MainActor @Observable
final class CommandQuestionModel {
    let commandName: String
    var itemTitle: String

    init(commandName: String, itemTitle: String) {
        self.commandName = commandName
        self.itemTitle = itemTitle
    }
}

/// Never the key window, so the app the user types in keeps the keyboard.
private final class QuestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a button works at once, also while another app is active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CommandQuestionView: View {
    let model: CommandQuestionModel
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Run \(model.commandName)?")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
            }
            Text(model.itemTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Not now") { onAnswer(false) }
                Button("Allow") { onAnswer(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: CommandConfirmationPanels.width)
    }
}
