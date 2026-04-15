import SwiftUI

struct FloatingIndicator: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        if coordinator.appState.isListening {
            HStack(spacing: 8) {
                WaveformAnimation()
                Text("Listening…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.9))
            .background(Color.red.opacity(0.7))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

struct WaveformAnimation: View {
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
        .onDisappear { animating = false }
    }
}
