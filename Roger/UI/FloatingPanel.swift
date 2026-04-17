import AppKit
import SwiftUI

@MainActor
final class FloatingPanel {
    private var panel: NSPanel?

    func show(coordinator: AppCoordinator) {
        guard panel == nil else { return }

        let hostingView = NSHostingView(
            rootView: FloatingIndicatorContent()
                .environment(coordinator)
                .padding(20)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 260, height: 110)

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

private struct FloatingIndicatorContent: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var pulseOpacity: Double = 1.0

    // Neon accent: hot pink while listening, electric cyan while thinking.
    // Drives the stroke, drop shadow and countdown warning tint.
    private static let listeningAccent = Color(red: 1.0, green: 0.2, blue: 0.48)
    private static let thinkingAccent = Color(red: 0.2, green: 0.87, blue: 1.0)

    private var isListening: Bool {
        coordinator.appState.dictationState == .listening
    }

    private var accent: Color {
        isListening ? Self.listeningAccent : Self.thinkingAccent
    }

    private var presetName: String? {
        guard let id = coordinator.activeRecordingPresetID else { return nil }
        return coordinator.appState.presets.first { $0.id == id }?.name
    }

    @ViewBuilder
    private var countdown: some View {
        if isListening, let start = coordinator.recordingStartTime {
            CountdownBadge(
                start: start,
                cap: coordinator.appState.maximumRecordingDuration,
                accent: accent
            )
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isListening {
                    PanelWaveform()
                        .transition(.opacity)
                } else {
                    SweepBar()
                        .transition(.opacity)
                }
            }
            .frame(width: 27, height: 20)
            .animation(.easeInOut(duration: 0.2), value: isListening)

            VStack(alignment: .leading, spacing: 1) {
                Text(isListening ? "Listening" : "Thinking")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                if let presetName {
                    Text("as \(presetName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isListening)

            countdown
        }
        .fixedSize()
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(pulseOpacity), lineWidth: 1.5)
        }
        .shadow(color: accent.opacity(0.55), radius: 16, y: 0)
        .shadow(color: accent.opacity(0.25), radius: 4, y: 0)
        .animation(.easeInOut(duration: 0.25), value: isListening)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.45
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
                    .fill(.primary)
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

private struct SweepBar: View {
    private let trackWidth: CGFloat = 27
    private let trackHeight: CGFloat = 3
    private let highlightWidth: CGFloat = 11
    @State private var offsetX: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
            .fill(.primary.opacity(0.18))
            .frame(width: trackWidth, height: trackHeight)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .primary.opacity(0.0),
                                .primary.opacity(0.6),
                                .primary,
                                .primary.opacity(0.6),
                                .primary.opacity(0.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: highlightWidth, height: trackHeight)
                    .offset(x: offsetX)
            }
            .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))
            .onAppear {
                offsetX = 0
                // Custom cubic Bezier accelerates quickly toward the middle and
                // lingers at the edges — the Cylon / KITT scanner feel.
                withAnimation(
                    .timingCurve(0.8, 0.0, 0.2, 1.0, duration: 0.6)
                        .repeatForever(autoreverses: true)
                ) {
                    offsetX = trackWidth - highlightWidth
                }
            }
    }
}

private struct CountdownBadge: View {
    let start: Date
    let cap: TimeInterval
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.25)) { context in
            let remaining = max(0, cap - context.date.timeIntervalSince(start))
            let warning = remaining <= 10
            let urgent = remaining <= 3

            Text(label(for: remaining, urgent: urgent))
                .font(.system(size: urgent ? 14 : 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(warning ? .white : .secondary)
                .padding(.horizontal, urgent ? 8 : 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(warning ? accent.opacity(0.85) : .clear)
                }
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.thinMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: warning ? accent.opacity(0.6) : .clear, radius: warning ? 6 : 0)
                .opacity(warning ? pulseOpacity(for: context.date) : 1)
                .animation(.easeInOut(duration: 0.2), value: warning)
        }
    }

    private func label(for remaining: TimeInterval, urgent: Bool) -> String {
        if urgent {
            return String(Int(ceil(remaining)))
        }
        let total = Int(ceil(remaining))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func pulseOpacity(for date: Date) -> Double {
        // 0.6s cadence: 0.9 ↔ 1.0
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.6) / 0.6
        let eased = (sin(phase * 2 * .pi) + 1) / 2
        return 0.9 + eased * 0.1
    }
}
