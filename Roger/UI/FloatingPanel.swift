import AppKit
import SwiftUI

@MainActor
final class FloatingPanel {
    private var panel: NSPanel?

    func show() {
        guard panel == nil else { return }

        let hostingView = NSHostingView(rootView: FloatingIndicatorContent())
        hostingView.frame = NSRect(x: 0, y: 0, width: 160, height: 44)

        let p = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.isMovableByWindowBackground = false
        p.contentView = hostingView

        // Position: centered horizontally, near top of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - hostingView.frame.width / 2
            let y = screenFrame.maxY - hostingView.frame.height - 60
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Standalone view for the floating panel (doesn't depend on Environment)
private struct FloatingIndicatorContent: View {
    var body: some View {
        HStack(spacing: 8) {
            PanelWaveform()
            Text("Listening…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.red.opacity(0.7))
        .clipShape(Capsule())
    }
}

private struct PanelWaveform: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3, height: animating ? CGFloat.random(in: 8...18) : 6)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                        value: animating
                    )
            }
        }
        .frame(height: 18)
        .onAppear { animating = true }
    }
}
