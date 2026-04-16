import AppKit
import SwiftUI

@MainActor
final class FloatingPanel {
    private var panel: NSPanel?

    func show() {
        guard panel == nil else { return }

        let hostingView = NSHostingView(rootView: FloatingIndicatorContent())
        hostingView.frame = NSRect(x: 0, y: 0, width: 180, height: 52)

        let p = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
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

/// macOS glass-style floating indicator
private struct FloatingIndicatorContent: View {
    var body: some View {
        HStack(spacing: 10) {
            PanelWaveform()
            Text("Listening")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                }
        }
    }
}

private struct PanelWaveform: View {
    @State private var phases: [Bool] = Array(repeating: false, count: 5)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: phases[index] ? barHeight(for: index) : 4)
                    .animation(
                        .easeInOut(duration: duration(for: index))
                        .repeatForever(autoreverses: true),
                        value: phases[index]
                    )
            }
        }
        .frame(width: 27, height: 20)
        .onAppear {
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
                    phases[i] = true
                }
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        switch index {
        case 0: return 12
        case 1: return 18
        case 2: return 20
        case 3: return 16
        case 4: return 10
        default: return 14
        }
    }

    private func duration(for index: Int) -> Double {
        switch index {
        case 0: return 0.5
        case 1: return 0.4
        case 2: return 0.35
        case 3: return 0.45
        case 4: return 0.55
        default: return 0.4
        }
    }
}
