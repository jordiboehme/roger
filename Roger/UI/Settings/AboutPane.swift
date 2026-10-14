import SwiftUI

/// Settings > About: icon, version, links and credits. Centered, not a form.
struct AboutPane: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            VStack(spacing: 4) {
                Text("Roger")
                    .font(.title.weight(.semibold))
                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Speech-to-Text for macOS")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link(destination: URL(string: "https://ko-fi.com/V7V31T6CL9")!) {
                    Label("Support Me", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .controlSize(.regular)

                Link(destination: URL(string: "https://github.com/jordiboehme/roger")!) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Spacer()

            VStack(spacing: 10) {
                Text("Powered by [FluidAudio](https://github.com/FluidInference/FluidAudio), [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) & [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .tint(.accentColor)

                Text("Created with \u{2764}\u{FE0F} by Jordi Böhme  \u{00B7}  MIT License")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
