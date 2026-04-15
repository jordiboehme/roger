import Foundation
import Observation

@Observable
final class AppState {
    enum DictationState: Equatable {
        case idle
        case listening
        case transcribing
        case processing
        case inserting
        case error(String)
    }

    var dictationState: DictationState = .idle
    var selectedLanguage: Language = .english
    var activationMode: ActivationMode = .pushToTalk
    var restoreClipboard: Bool = true
    var minimumRecordingDuration: TimeInterval = 1.5
    var lastTranscription: String?
    var modelDownloadProgress: Double?

    var isListening: Bool {
        dictationState == .listening
    }

    var isBusy: Bool {
        switch dictationState {
        case .transcribing, .processing, .inserting:
            return true
        default:
            return false
        }
    }

    var menuBarIcon: String {
        switch dictationState {
        case .idle:
            return "waveform"
        case .listening:
            return "waveform.circle.fill"
        case .transcribing, .processing:
            return "ellipsis.circle"
        case .inserting:
            return "text.cursor"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch dictationState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .processing:
            return "Processing…"
        case .inserting:
            return "Inserting…"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

enum Language: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable, Codable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk: return "Push to Talk (hold to record)"
        case .toggle: return "Toggle (press to start/stop)"
        }
    }
}
